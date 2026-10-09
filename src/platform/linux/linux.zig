//! Linux platform backend (gpui_linux): Wayland (preferred when `WAYLAND_DISPLAY` is set)
//! or X11 (`DISPLAY`), an epoll event loop with eventfd/timerfd, a worker-pool dispatcher,
//! and Vulkan surfaces for the renderer in src/renderer/vulkan.
//!
//!     const plat = try linux.create(gpa, .{ .io = io });
//!     defer plat.deinit();
//!     plat.run(.{ .ctx = &app, .func = App.onLaunch });

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");

pub const event_loop = @import("event_loop.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const keyboard = @import("keyboard.zig");
pub const window_common = @import("window_common.zig");
pub const util = @import("util.zig");
pub const vk_surface = @import("vk_surface.zig");
pub const presenter = @import("presenter.zig");
pub const wayland = @import("wayland.zig");
pub const x11 = @import("x11.zig");
pub const appearance = @import("appearance.zig");
pub const dbus = @import("dbus.zig");
pub const file_dialog = @import("file_dialog.zig");
pub const notifications = @import("notifications.zig");
pub const atspi = @import("atspi.zig");
pub const window_capture = @import("window_capture.zig");
pub const global_input = @import("global_input.zig");
pub const tray = @import("tray.zig");
pub const desktop_style = @import("desktop_style.zig");
const text_mod = @import("../../text/text.zig");

pub const BackendKind = enum { wayland, x11 };

pub const Options = struct {
    /// Used for the dispatcher's mutexes/condition variables. Defaults to a process-global
    /// single-threaded `Io.Threaded` (its futex ops work across threads).
    io: ?Io = null,
    /// Force a backend; by default Wayland when `WAYLAND_DISPLAY` is set, else X11.
    backend: ?BackendKind = null,
    /// Background worker threads; null = CPU count.
    worker_threads: ?usize = null,
};

pub const Backend = union(BackendKind) {
    wayland: *wayland.Client,
    x11: *x11.Client,
};

pub const LinuxPlatform = struct {
    gpa: Allocator,
    loop: event_loop.EventLoop,
    disp: dispatcher.LinuxDispatcher,
    backend: Backend,
    callbacks: platform.PlatformCallbacks = .{},
    text_system: platform.TextSystem,
    quit_requested: bool = false,
    cursor_style: platform.CursorStyle = .arrow,
    /// System light/dark (settings portal / gsettings; light when unknown).
    appearance: platform.WindowAppearance = .light,
    appearance_watcher: ?*appearance.Watcher = null,
    /// Drawn native controls: desktop look (desktop_style.zig) and the accent when no
    /// portal watcher keeps it current.
    desktop_style: platform.DesktopStyle = .adwaita,
    accent: ?u32 = null,
    /// Desktop banners (notifications.zig), created on the first `postNotification`.
    notifier: ?*notifications.Notifier = null,
    /// AT-SPI2 accessibility bridge (atspi.zig); null without a session bus or when
    /// disabled (`ZPUI_NO_A11Y=1` / `NO_AT_BRIDGE=1`).
    atspi: ?*atspi.Bridge = null,
    /// Global hotkey + window capture (window_capture.zig), created on first use.
    capture: ?*window_capture.Service = null,
    /// Global input monitor (global_input.zig) while running.
    input_monitor: ?*global_input.Monitor = null,
    /// StatusNotifierItem (tray.zig) while a tray item is set.
    tray_item: ?*tray.Tray = null,

    /// Ends `run` after the current loop iteration.
    pub fn requestQuit(self: *LinuxPlatform) void {
        self.quit_requested = true;
        self.loop.wake();
    }

    pub fn platformInterface(self: *LinuxPlatform) platform.Platform {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform.Platform.VTable = .{
        .dispatcher = getDispatcher,
        .textSystem = textSystem,
        .setCallbacks = setCallbacks,
        .run = run,
        .quit = quit,
        .activate = activate,
        .openWindow = openWindow,
        .displays = displays,
        .windowAppearance = windowAppearance,
        .setCursorStyle = setCursorStyle,
        .writeClipboard = writeClipboard,
        .readClipboard = readClipboard,
        .openUrl = openUrl,
        .revealPath = revealPath,
        .prefersReducedMotion = prefersReducedMotion,
        .deinit = deinitFn,
        .readClipboardImage = readClipboardImage,
        .promptForPaths = promptForPaths,
        .postNotification = postNotification,
        .playSound = playSound,
        .setGlobalHotkey = setGlobalHotkey,
        .windowCaptureCapabilities = windowCaptureCapabilities,
        .captureActiveWindow = captureActiveWindow,
        .startGlobalInputMonitor = startGlobalInputMonitor,
        .stopGlobalInputMonitor = stopGlobalInputMonitor,
        .setPreciseInput = setPreciseInput,
        .inputPermission = inputPermission,
        .requestInputPermission = requestInputPermission,
        .setTrayItem = setTrayItem,
        .foregroundApp = foregroundApp,
        .setForegroundAppCallback = setForegroundAppCallback,
        .setLaunchAtLogin = setLaunchAtLogin,
        .launchAtLoginEnabled = launchAtLoginEnabled,
        .desktopTheme = desktopTheme,
    };

    // -- desktop companion features (docs/DESKTOP_OVERLAY.md) --------------------------

    fn startGlobalInputMonitor(ptr: *anyopaque, cb: platform.Callback(platform.GlobalInputEvent, void)) platform.InputMonitorStatus {
        const self = cast(ptr);
        stopGlobalInputMonitor(ptr);
        const r = global_input.Monitor.start(self.gpa, &self.loop, cb, self.backend == .wayland) catch return .unsupported;
        self.input_monitor = r.monitor;
        return r.status;
    }
    fn stopGlobalInputMonitor(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.input_monitor) |m| m.destroy();
        self.input_monitor = null;
    }
    /// Every Linux backend is already precise (keycodes, no characters).
    fn setPreciseInput(_: *anyopaque, _: bool) void {}
    fn inputPermission(ptr: *anyopaque) platform.InputPermission {
        // X11: XInput2 needs no permission. Wayland: read access to /dev/input/event*.
        return switch (cast(ptr).backend) {
            .x11 => .not_applicable,
            .wayland => global_input.evdevReadable(),
        };
    }
    fn requestInputPermission(ptr: *anyopaque) void {
        // No OS prompt exists: input devices are readable by the `input` group.
        if (cast(ptr).backend == .wayland and global_input.evdevReadable() != .granted)
            std.log.scoped(.linux).warn("global input on Wayland needs read access to /dev/input/event*: add the user to the `input` group (sudo usermod -aG input $USER) and log in again", .{});
    }
    fn setTrayItem(ptr: *anyopaque, item: ?platform.TrayItem) anyerror!void {
        const self = cast(ptr);
        const it = item orelse {
            if (self.tray_item) |t| t.destroy();
            self.tray_item = null;
            return;
        };
        if (self.tray_item == null) self.tray_item = try tray.Tray.create(self.gpa, &self.loop, &self.callbacks, .fromProcess());
        try self.tray_item.?.set(appIdForTray(), it);
    }
    var exe_name_buf: [256]u8 = undefined;
    /// The executable's basename (the SNI `Id`).
    fn appIdForTray() []const u8 {
        const n = std.os.linux.readlink("/proc/self/exe", &exe_name_buf, exe_name_buf.len);
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) return "zpui";
        return std.fs.path.basename(exe_name_buf[0..n]);
    }
    fn foregroundApp(ptr: *anyopaque, buf: []u8) ?platform.ForegroundApp {
        return switch (cast(ptr).backend) {
            inline else => |b| b.foregroundApp(buf),
        };
    }
    fn setForegroundAppCallback(ptr: *anyopaque, cb: platform.Callback(void, void)) void {
        switch (cast(ptr).backend) {
            inline else => |b| b.setForegroundCallback(cb),
        }
    }
    /// XDG autostart: `~/.config/autostart/<app_id>.desktop`.
    fn setLaunchAtLogin(_: *anyopaque, app_id: []const u8, exe_path: []const u8, on: bool) anyerror!void {
        var path_buf: [4096]u8 = undefined;
        const path = try platform.desktop.autostartPath(&path_buf, envVar("XDG_CONFIG_HOME"), envVar("HOME"), app_id);
        try writeOrRemove(path, if (on) .{ .app_id = app_id, .exe_path = exe_path } else null);
    }
    /// The autostart entry `setLaunchAtLogin` writes exists and is not switched off.
    fn launchAtLoginEnabled(_: *anyopaque, app_id: []const u8) anyerror!bool {
        var path_buf: [4096]u8 = undefined;
        const path = try platform.desktop.autostartPath(&path_buf, envVar("XDG_CONFIG_HOME"), envVar("HOME"), app_id);
        return autostartEntryActive(path);
    }
    fn envVar(name: [*:0]const u8) ?[]const u8 {
        return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
    }

    fn desktopTheme(ptr: *anyopaque) platform.DesktopTheme {
        const self = cast(ptr);
        const accent = if (self.appearance_watcher) |w| w.accent else self.accent;
        return .{ .style = self.desktop_style, .accent = accent };
    }

    fn captureService(self: *LinuxPlatform) ?*window_capture.Service {
        if (self.capture == null) {
            self.capture = window_capture.Service.create(self.gpa, self.disp.io, self.disp.dispatcher(), .fromProcess()) catch return null;
        }
        return self.capture;
    }
    fn setGlobalHotkey(ptr: *anyopaque, hotkey: ?platform.GlobalHotkey, handler: platform.GlobalHotkeyHandler) void {
        if (cast(ptr).captureService()) |s| s.setHotkey(hotkey, handler);
    }
    fn windowCaptureCapabilities(ptr: *anyopaque) platform.WindowCaptureCapabilities {
        const s = cast(ptr).captureService() orelse return .{};
        return s.capabilities();
    }
    fn captureActiveWindow(ptr: *anyopaque, gpa: Allocator, done: platform.WindowCaptureCallback) void {
        const s = cast(ptr).captureService() orelse {
            var r: platform.WindowCaptureResult = .{ .err = .{ .failed = gpa.dupe(u8, "Appshot capture is unavailable.") catch &.{} } };
            return done.done(done.ctx, gpa, &r);
        };
        s.capture(gpa, done);
    }

    fn postNotification(ptr: *anyopaque, n: platform.Notification) void {
        const self = cast(ptr);
        if (self.notifier == null) {
            self.notifier = notifications.Notifier.create(self.gpa, self.disp.io, self.disp.dispatcher(), &self.callbacks, .fromProcess()) catch return;
        }
        self.notifier.?.post(n);
    }
    fn playSound(ptr: *anyopaque, bytes: []const u8) void {
        notifications.playSound(cast(ptr).gpa, bytes);
    }

    fn cast(ptr: *anyopaque) *LinuxPlatform {
        return @ptrCast(@alignCast(ptr));
    }

    fn getDispatcher(ptr: *anyopaque) platform.Dispatcher {
        return cast(ptr).disp.dispatcher();
    }
    fn textSystem(ptr: *anyopaque) platform.TextSystem {
        return cast(ptr).text_system;
    }
    fn setCallbacks(ptr: *anyopaque, cbs: platform.PlatformCallbacks) void {
        cast(ptr).callbacks = cbs;
    }
    fn run(ptr: *anyopaque, on_launch: platform.Callback(void, void)) void {
        const self = cast(ptr);
        _ = on_launch.call({});
        while (!self.quit_requested) self.loop.poll(-1);
        if (self.callbacks.quit) |f| f(self.callbacks.ctx);
    }
    fn quit(ptr: *anyopaque) void {
        cast(ptr).requestQuit();
    }
    fn activate(_: *anyopaque, _: bool) void {}
    fn openWindow(ptr: *anyopaque, params: platform.WindowParams) anyerror!platform.Window {
        return switch (cast(ptr).backend) {
            inline else => |b| b.openWindow(params),
        };
    }
    fn displays(ptr: *anyopaque, out: []platform.Display) usize {
        return switch (cast(ptr).backend) {
            inline else => |b| b.displays(out),
        };
    }
    fn windowAppearance(ptr: *anyopaque) platform.WindowAppearance {
        return cast(ptr).appearance;
    }

    /// Portal `SettingChanged`: record it and fire every window's appearance callback.
    fn onAppearanceChanged(ctx: ?*anyopaque, value: platform.WindowAppearance) void {
        const self: *LinuxPlatform = @ptrCast(@alignCast(ctx.?));
        self.appearance = value;
        switch (self.backend) {
            inline else => |b| for (b.windows.items) |w| w.common.appearanceChanged(),
        }
    }
    fn setCursorStyle(ptr: *anyopaque, style: platform.CursorStyle) void {
        const self = cast(ptr);
        self.cursor_style = style;
        switch (self.backend) {
            inline else => |b| b.setCursorStyle(style),
        }
    }
    fn writeClipboard(ptr: *anyopaque, text: []const u8) void {
        switch (cast(ptr).backend) {
            inline else => |b| b.writeClipboard(text),
        }
    }
    fn readClipboard(ptr: *anyopaque, gpa: Allocator) ?[]u8 {
        return switch (cast(ptr).backend) {
            inline else => |b| b.readClipboard(gpa),
        };
    }
    fn readClipboardImage(ptr: *anyopaque, gpa: Allocator) ?platform.ClipboardImage {
        return switch (cast(ptr).backend) {
            inline else => |b| b.readClipboardImage(gpa),
        };
    }
    fn promptForPaths(ptr: *anyopaque, options: platform.PathPromptOptions, done: platform.PathsCallback) void {
        const self = cast(ptr);
        file_dialog.prompt(self.gpa, self.disp.dispatcher(), options, done);
    }
    fn openUrl(ptr: *anyopaque, url: []const u8) void {
        spawnDetached(cast(ptr).gpa, &.{ "xdg-open", url });
    }
    fn revealPath(ptr: *anyopaque, path: []const u8) void {
        // gpui uses the FileManager1 D-Bus portal; opening the parent directory is the fallback.
        spawnDetached(cast(ptr).gpa, &.{ "xdg-open", std.fs.path.dirname(path) orelse path });
    }
    fn prefersReducedMotion(_: *anyopaque) bool {
        return false;
    }
    fn deinitFn(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.appearance_watcher) |w| w.destroy();
        if (self.notifier) |n| n.destroy();
        if (self.atspi) |a| a.destroy();
        self.atspi = null;
        if (self.capture) |c| c.destroy();
        self.capture = null;
        if (self.input_monitor) |m| m.destroy();
        self.input_monitor = null;
        if (self.tray_item) |t| t.destroy();
        self.tray_item = null;
        switch (self.backend) {
            inline else => |b| b.destroy(),
        }
        self.disp.deinit();
        text_mod.destroyPlatformTextSystem(self.text_system);
        self.loop.deinit();
        self.gpa.destroy(self);
    }
};

/// Whether the autostart entry at `path` exists and is enabled (see
/// `desktop.autostartEntryEnabled`). Entries are a few hundred bytes; only the first
/// 16 KiB are read.
fn autostartEntryActive(path: []const u8) !bool {
    const linux = std.os.linux;
    var zbuf: [4097]u8 = undefined;
    if (path.len >= zbuf.len) return error.NameTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd_rc = linux.open(zbuf[0..path.len :0], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (linux.errno(fd_rc)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return false,
        else => return error.ReadFailed,
    }
    const fd: linux.fd_t = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (n == 0) break;
        len += n;
    }
    return platform.desktop.autostartEntryEnabled(buf[0..len]);
}

/// Writes the autostart entry (creating the directory) or deletes it.
fn writeOrRemove(path: []const u8, entry: ?struct { app_id: []const u8, exe_path: []const u8 }) !void {
    const linux = std.os.linux;
    var zbuf: [4097]u8 = undefined;
    if (path.len >= zbuf.len) return error.NameTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const pathz: [*:0]const u8 = zbuf[0..path.len :0];
    const e = entry orelse {
        const rc = linux.unlink(pathz);
        return switch (linux.errno(rc)) {
            .SUCCESS, .NOENT => {},
            else => error.RemoveFailed,
        };
    };
    // mkdir -p of the parent.
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            var d: [4097]u8 = undefined;
            @memcpy(d[0..i], dir[0..i]);
            d[i] = 0;
            _ = linux.mkdir(d[0..i :0], 0o755);
        }
    }
    var out: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try platform.desktop.writeAutostartEntry(&w, e.app_id, e.exe_path);
    const fd_rc = linux.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(fd_rc) != .SUCCESS) return error.WriteFailed;
    const fd: linux.fd_t = @intCast(fd_rc);
    defer _ = linux.close(fd);
    const data = w.buffered();
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        off += n;
    }
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Fire-and-forget `fork`+`execvp` (child double-forks so no zombie is left behind).
fn spawnDetached(gpa: Allocator, argv: []const []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return;
    for (argv, 0..) |a, i| argv_z[i] = (arena.dupeSentinel(u8, a, 0) catch return).ptr;
    const linux = std.os.linux;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return;
    if (pid == 0) {
        if (linux.fork() == 0) {
            _ = execvp(argv_z[0].?, argv_z.ptr);
        }
        linux.exit(0);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

/// Creates the Linux platform (gpui `current_platform`).
pub fn create(gpa: Allocator, options: Options) !platform.Platform {
    const self = try gpa.create(LinuxPlatform);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .loop = try event_loop.EventLoop.init(gpa),
        .disp = undefined,
        .backend = undefined,
        .text_system = undefined,
    };
    errdefer self.loop.deinit();
    const io = options.io orelse std.Io.Threaded.global_single_threaded.io();
    try self.disp.init(gpa, io, &self.loop, options.worker_threads);
    errdefer self.disp.deinit();
    self.text_system = try text_mod.createPlatformTextSystem(gpa);
    errdefer text_mod.destroyPlatformTextSystem(self.text_system);

    const kind = options.backend orelse if (std.c.getenv("WAYLAND_DISPLAY") != null) BackendKind.wayland else .x11;
    self.backend = switch (kind) {
        .wayland => if (wayland.Client.create(gpa, self)) |client| .{ .wayland = client } else |e| blk: {
            if (options.backend != null or std.c.getenv("DISPLAY") == null) return e;
            std.log.scoped(.linux).warn("Wayland unavailable ({t}); falling back to X11", .{e});
            break :blk .{ .x11 = try x11.Client.create(gpa, self) };
        },
        .x11 => .{ .x11 = try x11.Client.create(gpa, self) },
    };
    if (std.c.getenv("ZPUI_NO_APPEARANCE_PORTAL") == null) {
        const started = appearance.Watcher.start(gpa, &self.loop, appearance.Watcher.envFromProcess(), .{ .ctx = self, .func = LinuxPlatform.onAppearanceChanged });
        self.appearance = started.appearance;
        self.appearance_watcher = started.watcher;
        self.accent = started.accent;
    }
    self.desktop_style = desktop_style.fromProcess();
    self.atspi = atspi.Bridge.create(gpa, &self.loop, .fromProcess());
    return self.platformInterface();
}

test {
    std.testing.refAllDecls(@This());
}
