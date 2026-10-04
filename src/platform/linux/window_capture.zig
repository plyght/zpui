//! Linux global hotkey + frontmost-window capture (zeron `appshots/linux/mod.rs`):
//! portal-first on Wayland, native X11 otherwise, AT-SPI text on X11.
//!
//! Wayland (`WAYLAND_DISPLAY` set): the hotkey is a `GlobalShortcuts` portal session
//! (rebound with `ConfigureShortcuts` when the chord changes; `setup_required` when the
//! desktop has no such portal or refuses it), and captures go through the `Screenshot`
//! portal's active-window target (v3 `AvailableTargets`), else its window picker. The
//! portal does not identify the captured window, so Wayland captures carry no
//! application text.
//!
//! X11: a passive key grab on the root window; captures prefer the Screenshot portal's
//! active-window target when one exists (no second attempt after a portal
//! cancellation or failure), else `GetImage` of `_NET_ACTIVE_WINDOW` enriched with
//! AT-SPI text when the window's PID + title identify exactly one accessible window.
//!
//! Threads: one hotkey thread (started by the first `setHotkey`, woken through an
//! eventfd) and one short-lived thread per capture. Results and presses reach the main
//! thread through the dispatcher.

const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const common = @import("../capture_common.zig");
const dbus = @import("dbus.zig");
const portal_mod = @import("portal_capture.zig");
const x11c = @import("x11_capture.zig");
const atspi_client = @import("atspi_client.zig");

const log = std.log.scoped(.window_capture);
const Portal = portal_mod.Portal;
const State = platform.CapabilityState;

pub const Env = struct {
    bus_address: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,
    home: ?[]const u8 = null,
    wayland: bool = false,

    pub fn fromProcess() Env {
        const get = struct {
            fn f(n: [*:0]const u8) ?[]const u8 {
                return if (std.c.getenv(n)) |p| std.mem.span(p) else null;
            }
        }.f;
        const wl = get("WAYLAND_DISPLAY");
        return .{
            .bus_address = get("DBUS_SESSION_BUS_ADDRESS"),
            .runtime_dir = get("XDG_RUNTIME_DIR"),
            .home = get("HOME"),
            .wayland = wl != null and wl.?.len > 0,
        };
    }
};

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    dispatcher: platform.Dispatcher,
    env: Env,
    refs: std.atomic.Value(u32) = .init(1),
    wake_fd: linux.fd_t,

    mutex: Io.Mutex = .init,
    // -- guarded by `mutex` -------------------------------------------------------------
    desired: ?platform.GlobalHotkey = null,
    desired_key: [32]u8 = undefined,
    desired_gen: u64 = 0,
    stopping: bool = false,

    // -- main thread ----------------------------------------------------------------------
    handler: ?platform.GlobalHotkeyHandler = null,
    thread_started: bool = false,

    // -- any thread -------------------------------------------------------------------------
    shortcut_state: std.atomic.Value(u8),
    capture_state: std.atomic.Value(u8),
    target: std.atomic.Value(u8),

    pub fn create(gpa: Allocator, io: Io, dispatcher: platform.Dispatcher, env: Env) !*Service {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFd;
        const self = try gpa.create(Service);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .dispatcher = dispatcher,
            .env = env,
            .wake_fd = @intCast(rc),
            .shortcut_state = .init(@intFromEnum(if (env.wayland) State.checking else State.ready)),
            .capture_state = .init(@intFromEnum(if (env.wayland) State.checking else State.ready)),
            .target = .init(@intFromEnum(if (env.wayland) platform.CaptureTarget.portal_window_picker else .active_window)),
        };
        return self;
    }

    /// Main thread: stop the hotkey thread (it frees the service when it exits).
    pub fn destroy(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        self.wake();
        self.release();
    }

    fn retain(self: *Service) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *Service) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = linux.close(self.wake_fd);
        self.gpa.destroy(self);
    }

    fn wake(self: *Service) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), 8);
    }

    fn drainWake(self: *Service) void {
        var v: u64 = 0;
        _ = linux.read(self.wake_fd, std.mem.asBytes(&v), 8);
    }

    fn isStopping(self: *Service) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopping;
    }

    /// The desired hotkey snapshot (key copied into `buf`).
    fn snapshot(self: *Service, buf: *[32]u8) struct { hotkey: ?platform.GlobalHotkey, gen: u64, stop: bool } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var h = self.desired;
        if (h) |*v| {
            @memcpy(buf[0..v.key.len], v.key);
            v.key = buf[0..v.key.len];
        }
        return .{ .hotkey = h, .gen = self.desired_gen, .stop = self.stopping };
    }

    // ---- main-thread API ---------------------------------------------------------------

    pub fn setHotkey(self: *Service, hotkey: ?platform.GlobalHotkey, handler: platform.GlobalHotkeyHandler) void {
        self.handler = handler;
        self.mutex.lockUncancelable(self.io);
        if (hotkey) |h| if (h.key.len <= self.desired_key.len) {
            @memcpy(self.desired_key[0..h.key.len], h.key);
            var copy = h;
            copy.key = self.desired_key[0..h.key.len];
            copy.description = "Capture an Appshot";
            copy.id = "capture-appshot";
            self.desired = copy;
        } else {
            self.desired = null;
        } else self.desired = null;
        self.desired_gen +%= 1;
        self.mutex.unlock(self.io);
        if (!self.thread_started) {
            self.retain();
            if (std.Thread.spawn(.{}, hotkeyMain, .{self})) |t| {
                t.detach();
                self.thread_started = true;
            } else |err| {
                self.release();
                log.warn("hotkey thread: {t}", .{err});
                self.shortcut_state.store(@intFromEnum(State.setup_required), .release);
            }
        }
        self.wake();
    }

    pub fn capabilities(self: *Service) platform.WindowCaptureCapabilities {
        if (self.env.wayland) return .{
            .system = .linux_wayland,
            .global_hotkey = @enumFromInt(self.shortcut_state.load(.acquire)),
            .window_capture = @enumFromInt(self.capture_state.load(.acquire)),
            .application_text = .unavailable,
            .target = @enumFromInt(self.target.load(.acquire)),
        };
        return .{
            .system = .linux_x11,
            .global_hotkey = @enumFromInt(self.shortcut_state.load(.acquire)),
            .window_capture = .ready,
            .application_text = .ready,
            .target = .active_window,
        };
    }

    pub fn capture(self: *Service, gpa: Allocator, done: platform.WindowCaptureCallback) void {
        const job = gpa.create(CaptureJob) catch {
            var r = common.failed(gpa, "Could not start the capture.", .{});
            return done.done(done.ctx, gpa, &r);
        };
        self.retain();
        job.* = .{ .service = self, .gpa = gpa, .done = done };
        const t = std.Thread.spawn(.{}, CaptureJob.main, .{job}) catch {
            self.release();
            gpa.destroy(job);
            var r = common.failed(gpa, "Could not start the capture.", .{});
            return done.done(done.ctx, gpa, &r);
        };
        t.detach();
    }

    // ---- activation delivery --------------------------------------------------------------

    const Activation = struct {
        service: *Service,
        fn run(ctx: *anyopaque) void {
            const a: *Activation = @ptrCast(@alignCast(ctx));
            const s = a.service;
            s.gpa.destroy(a);
            defer s.release();
            if (s.isStopping()) return;
            if (s.handler) |h| h.func(h.ctx);
        }
        fn drop(ctx: *anyopaque) void {
            const a: *Activation = @ptrCast(@alignCast(ctx));
            const s = a.service;
            s.gpa.destroy(a);
            s.release();
        }
    };

    fn activate(self: *Service) void {
        const a = self.gpa.create(Activation) catch return;
        a.* = .{ .service = self };
        self.retain();
        self.dispatcher.dispatchOnMainThread(.{ .ctx = a, .run = Activation.run, .drop = Activation.drop }, .high);
    }

    // ---- hotkey thread ----------------------------------------------------------------------

    fn hotkeyMain(self: *Service) void {
        defer self.release();
        if (self.env.wayland) {
            self.probeCapture();
            self.portalLoop();
        } else self.x11Loop();
    }

    fn setShortcut(self: *Service, s: State) void {
        self.shortcut_state.store(@intFromEnum(s), .release);
    }

    fn x11Loop(self: *Service) void {
        var grab = x11c.Grab.open() orelse {
            log.warn("X11 Appshot shortcut could not be registered: no X connection", .{});
            return self.setShortcut(.setup_required);
        };
        defer grab.close();
        var applied: ?u64 = null;
        var key_buf: [32]u8 = undefined;
        while (true) {
            const snap = self.snapshot(&key_buf);
            if (snap.stop) return;
            if (applied == null or applied.? != snap.gen) {
                applied = snap.gen;
                if (snap.hotkey) |h| {
                    const ok = grab.grab(h);
                    self.setShortcut(if (ok) .ready else .setup_required);
                    if (!ok) log.warn("X11 Appshot shortcut could not be registered", .{});
                } else grab.ungrab();
                _ = grab.drain();
            }
            var fds = [2]linux.pollfd{
                .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = grab.fd(), .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, 2, -1);
            if (linux.errno(rc) != .SUCCESS) continue;
            if (fds[0].revents != 0) self.drainWake();
            var n = grab.drain();
            while (n > 0) : (n -= 1) self.activate();
            if (grab.broken()) {
                self.setShortcut(.setup_required);
                return;
            }
        }
    }

    fn onWake(ctx: ?*anyopaque) bool {
        const self: *Service = @ptrCast(@alignCast(ctx.?));
        self.drainWake();
        return self.isStopping();
    }

    fn openPortal(self: *Service) ?Portal {
        var p = Portal.open(self.gpa, self.env.bus_address, self.env.runtime_dir) orelse return null;
        p.wake_fd = self.wake_fd;
        p.should_stop = onWake;
        p.stop_ctx = self;
        return p;
    }

    /// `probe_capture`: Screenshot portal version + available targets.
    fn probeCapture(self: *Service) void {
        var p = Portal.open(self.gpa, self.env.bus_address, self.env.runtime_dir) orelse {
            self.capture_state.store(@intFromEnum(State.unavailable), .release);
            return;
        };
        defer p.deinit();
        const info = p.screenshotTargets() orelse {
            self.capture_state.store(@intFromEnum(State.unavailable), .release);
            return;
        };
        if (info.version < 3) {
            self.capture_state.store(@intFromEnum(State.unavailable), .release);
            self.target.store(@intFromEnum(platform.CaptureTarget.portal_window_picker), .release);
        } else if (info.targets & portal_mod.Target.active_window != 0) {
            self.capture_state.store(@intFromEnum(State.ready), .release);
            self.target.store(@intFromEnum(platform.CaptureTarget.active_window), .release);
        } else if (info.targets & portal_mod.Target.window != 0) {
            self.capture_state.store(@intFromEnum(State.user_selection), .release);
            self.target.store(@intFromEnum(platform.CaptureTarget.portal_window_picker), .release);
        } else {
            self.capture_state.store(@intFromEnum(State.unavailable), .release);
        }
    }

    /// Wait for the desired hotkey to change (or stop). Returns false when stopping.
    fn waitForChange(self: *Service, since: u64) bool {
        var key_buf: [32]u8 = undefined;
        while (true) {
            const snap = self.snapshot(&key_buf);
            if (snap.stop) return false;
            if (snap.gen != since) return true;
            var fds = [1]linux.pollfd{.{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, -1);
            self.drainWake();
        }
    }

    fn portalLoop(self: *Service) void {
        var last_bound: ?platform.GlobalHotkey = null;
        var last_key: [32]u8 = undefined;
        var key_buf: [32]u8 = undefined;
        while (true) {
            const snap = self.snapshot(&key_buf);
            if (snap.stop) return;
            const selected = snap.hotkey orelse {
                if (!self.waitForChange(snap.gen)) return;
                continue;
            };
            const configure = if (last_bound) |old| !old.eql(selected) else false;
            if (self.runShortcutSession(selected, configure, snap.gen)) |_| {
                @memcpy(last_key[0..selected.key.len], selected.key);
                last_bound = selected;
                last_bound.?.key = last_key[0..selected.key.len];
            } else |err| {
                if (err == error.Stopped) return;
                log.warn("Wayland global-shortcut portal unavailable: {t}", .{err});
                self.setShortcut(.setup_required);
                if (!self.waitForChange(snap.gen)) return;
            }
        }
    }

    /// `run_shortcut`: one portal session for `selected`; returns once the desired
    /// hotkey differs from it (the session is always closed first).
    fn runShortcutSession(self: *Service, selected: platform.GlobalHotkey, configure: bool, gen: u64) !void {
        var p = self.openPortal() orelse return error.NoBus;
        defer p.deinit();
        const gpa = self.gpa;
        const version = try p.getU32(portal_mod.shortcuts_iface, "version");
        // CreateSession.
        var htok_buf: [48]u8 = undefined;
        const htok = portal_mod.nextToken(&htok_buf);
        var stok_buf: [48]u8 = undefined;
        const stok = portal_mod.nextToken(&stok_buf);
        var spath_buf: [256]u8 = undefined;
        const expected_session = portal_mod.sessionPath(&spath_buf, p.conn.uniqueName(), stok) orelse return error.BadMessage;
        const cs_body = try portal_mod.createSessionBody(gpa, htok, stok);
        defer gpa.free(cs_body);
        var session_buf: [256]u8 = undefined;
        const session: []const u8 = blk: {
            const m = try p.request(portal_mod.shortcuts_iface, "CreateSession", "a{sv}", cs_body, htok);
            const resp = try portal_mod.parseResponse(m, "session_handle");
            if (resp.code != 0) return error.Refused;
            const h = resp.value orelse expected_session;
            if (h.len > session_buf.len) return error.BadMessage;
            @memcpy(session_buf[0..h.len], h);
            break :blk session_buf[0..h.len];
        };
        // Always close the session before rebinding, including after a refusal.
        defer p.closeSession(session);
        var trig_buf: [64]u8 = undefined;
        const trigger = common.portalTrigger(&trig_buf, selected);
        var btok_buf: [48]u8 = undefined;
        const btok = portal_mod.nextToken(&btok_buf);
        const bind_body = try portal_mod.bindShortcutsBody(gpa, session, selected.id, selected.description, trigger, btok);
        defer gpa.free(bind_body);
        {
            const m = try p.request(portal_mod.shortcuts_iface, "BindShortcuts", "oa(sa{sv})sa{sv}", bind_body, btok);
            const resp = try portal_mod.parseResponse(m, "");
            if (resp.code != 0) return error.Refused;
        }
        if (configure and version >= 2) {
            const body = try portal_mod.configureShortcutsBody(gpa, session);
            defer gpa.free(body);
            const serial = p.conn.send(.{ .serial = 0, .destination = portal_mod.dest, .path = portal_mod.path, .interface = portal_mod.shortcuts_iface, .member = "ConfigureShortcuts", .body = .{ .bytes = body, .signature = "osa{sv}" } }) catch return error.WriteFailed;
            const m = try p.reply(serial, 5000);
            if (m.type == .err) return error.Refused;
        }
        self.setShortcut(.ready);
        try p.addMatch("type='signal',interface='" ++ portal_mod.shortcuts_iface ++ "',member='Activated'");
        var key_buf: [32]u8 = undefined;
        var seen_gen = gen;
        while (true) {
            const m = p.next(-1) catch |err| switch (err) {
                error.Woken => {
                    const snap = self.snapshot(&key_buf);
                    if (snap.stop) return error.Stopped;
                    if (snap.gen != seen_gen) {
                        seen_gen = snap.gen;
                        const same = if (snap.hotkey) |h| h.eql(selected) else false;
                        if (!same) return;
                    }
                    continue;
                },
                else => return err,
            };
            if (m.type != .signal or !std.mem.eql(u8, m.member, "Activated") or !std.mem.eql(u8, m.interface, portal_mod.shortcuts_iface)) continue;
            const a = portal_mod.parseActivated(m) catch continue;
            if (std.mem.eql(u8, a.session, session) and std.mem.eql(u8, a.id, selected.id)) self.activate();
        }
    }

    // ---- captures ---------------------------------------------------------------------------

    const CaptureJob = struct {
        service: *Service,
        gpa: Allocator,
        done: platform.WindowCaptureCallback,
        result: platform.WindowCaptureResult = undefined,

        fn main(job: *CaptureJob) void {
            job.result = job.service.captureBlocking(job.gpa);
            job.service.dispatcher.dispatchOnMainThread(.{ .ctx = job, .run = finish, .drop = drop }, .high);
        }

        fn finish(ctx: *anyopaque) void {
            const job: *CaptureJob = @ptrCast(@alignCast(ctx));
            const s = job.service;
            if (job.result == .ok) if (job.done.pixels_ready) |f| f(job.done.ctx);
            job.done.done(job.done.ctx, job.gpa, &job.result);
            job.gpa.destroy(job);
            s.release();
        }

        fn drop(ctx: *anyopaque) void {
            const job: *CaptureJob = @ptrCast(@alignCast(ctx));
            const s = job.service;
            job.result.deinit(job.gpa);
            job.gpa.destroy(job);
            s.release();
        }
    };

    fn captureBlocking(self: *Service, gpa: Allocator) platform.WindowCaptureResult {
        if (self.env.wayland) {
            self.probeCapture();
            const target: platform.CaptureTarget = @enumFromInt(self.target.load(.acquire));
            return self.captureTarget(gpa, target);
        }
        // A passive X11 grab can blur our window; check the WM's active PID too,
        // before any portal consent.
        if (x11c.viewerIsActive(gpa)) return .{ .err = .self_capture };
        if (self.activeWindowSupported()) {
            // Once a portal operation starts, its cancellation, denial or failure ends
            // the capture: native fallback is only for an unavailable capability.
            return self.captureTarget(gpa, .active_window);
        }
        return self.captureX11(gpa);
    }

    fn activeWindowSupported(self: *Service) bool {
        var p = Portal.open(self.gpa, self.env.bus_address, self.env.runtime_dir) orelse return false;
        defer p.deinit();
        const info = p.screenshotTargets() orelse return false;
        return info.version >= 3 and info.targets & portal_mod.Target.active_window != 0;
    }

    /// `capture_target`: a Screenshot portal capture (no semantics: the portal does not
    /// identify the window).
    fn captureTarget(self: *Service, gpa: Allocator, target: platform.CaptureTarget) platform.WindowCaptureResult {
        var p = Portal.open(gpa, self.env.bus_address, self.env.runtime_dir) orelse
            return common.failed(gpa, "Screenshot portal unavailable: no session bus.", .{});
        defer p.deinit();
        const requested: u32 = if (target == .active_window) portal_mod.Target.active_window else portal_mod.Target.window;
        const info = p.screenshotTargets() orelse return common.failed(gpa, "Screenshot portal unavailable: the desktop portal did not answer.", .{});
        if (info.version < 3 or info.targets & requested == 0)
            return common.failed(gpa, "This screenshot portal does not support window-only capture. Update your desktop portal to use Appshots.", .{});
        const outcome = p.screenshot(requested, target == .portal_window_picker) catch |err|
            return common.failed(gpa, "Screenshot portal failed: {t}", .{err});
        const file_path = switch (outcome) {
            .cancelled => return .{ .err = .cancelled },
            .failed => |msg| return common.failed(gpa, "{s}", .{msg}),
            .path => |pp| pp,
        };
        defer gpa.free(file_path);
        const bytes = readCapped(gpa, file_path) catch |err| return switch (err) {
            error.TooLarge => common.failed(gpa, "The portal screenshot is larger than Zeron's 24 MB image limit.", .{}),
            error.Changed => common.failed(gpa, "The portal screenshot changed size while it was being read.", .{}),
            error.OpenFailed => common.failed(gpa, "Could not open portal screenshot.", .{}),
            else => common.failed(gpa, "Could not read portal screenshot: {t}", .{err}),
        };
        const app_name = gpa.dupe(u8, "Selected window") catch {
            gpa.free(bytes);
            return common.failed(gpa, "Out of memory.", .{});
        };
        const bundle = gpa.dupe(u8, if (target == .active_window) "linux-portal:active-window" else "linux-portal:selection") catch null;
        return .{ .ok = .{ .png = bytes, .app_name = app_name, .bundle_identifier = bundle } };
    }

    /// `x11::capture`: native pixels, then AT-SPI text when the identity is unique and
    /// unchanged afterwards.
    fn captureX11(self: *Service, gpa: Allocator) platform.WindowCaptureResult {
        var native = switch (x11c.captureNative(gpa, self.env.home)) {
            .ok => |n| n,
            .err => |e| return e,
        };
        var semantic: ?atspi_client.Semantic = null;
        if (native.identity) |id| {
            semantic = atspi_client.captureWindow(gpa, .{ .bus_address = self.env.bus_address, .runtime_dir = self.env.runtime_dir, .at_spi_address = if (std.c.getenv("AT_SPI_BUS_ADDRESS")) |a| std.mem.span(a) else null }, id.pid, id.title);
            // AT-SPI and X11 share no window id: the X window must be unchanged too.
            const now = x11c.currentIdentity(gpa);
            defer if (now) |n| gpa.free(n.title);
            const same = if (now) |n| n.eql(id) else false;
            if (!same) if (semantic) |*s| {
                s.deinit(gpa);
                semantic = null;
            };
        }
        defer if (semantic) |*s| s.deinit(gpa);
        const app_name: []const u8 = if (native.desktop) |d| (d.name orelse fallbackName(semantic, native.wm_class)) else fallbackName(semantic, native.wm_class);
        const bundle: ?[]u8 = if (native.desktop) |d| (if (d.id) |id| gpa.dupe(u8, id) catch null else null) else null;
        const bundle_final = bundle orelse if (native.wm_class) |cls| std.fmt.allocPrint(gpa, "linux-x11:{s}", .{cls}) catch null else null;
        var out: platform.WindowCapture = .{
            .png = native.png,
            .app_name = gpa.dupe(u8, app_name) catch &.{},
            .bundle_identifier = bundle_final,
            .window_title = native.title,
            .accessibility = if (semantic) |s| (gpa.dupe(u8, s.content) catch &.{}) else &.{},
            .accessibility_truncated = if (semantic) |s| s.truncated else false,
            .icon_png = native.icon_png,
        };
        // Moved into `out`.
        native.png = &.{};
        native.title = null;
        native.icon_png = null;
        native.deinit(gpa);
        if (out.app_name.len == 0) {
            out.deinit(gpa);
            return common.failed(gpa, "Out of memory.", .{});
        }
        return .{ .ok = out };
    }

    fn fallbackName(semantic: ?atspi_client.Semantic, wm_class: ?[]const u8) []const u8 {
        if (semantic) |s| return s.app_name;
        return wm_class orelse "X11 application";
    }
};

fn readCapped(gpa: Allocator, file_path: []const u8) ![]u8 {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (file_path.len >= path_z.len) return error.OpenFailed;
    @memcpy(path_z[0..file_path.len], file_path);
    path_z[file_path.len] = 0;
    const rc = linux.open(@ptrCast(&path_z), .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) != .SUCCESS) return error.StatFailed;
    if (st.size > common.max_attachment_bytes) return error.TooLarge;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, @intCast(st.size));
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + n > common.max_attachment_bytes) return error.Changed;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

test {
    _ = common;
    _ = portal_mod;
    _ = x11c;
    _ = atspi_client;
}
