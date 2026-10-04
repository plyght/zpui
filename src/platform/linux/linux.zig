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
    /// Desktop banners (notifications.zig), created on the first `postNotification`.
    notifier: ?*notifications.Notifier = null,
    /// AT-SPI2 accessibility bridge (atspi.zig); null without a session bus or when
    /// disabled (`ZPUI_NO_A11Y=1` / `NO_AT_BRIDGE=1`).
    atspi: ?*atspi.Bridge = null,
    /// Global hotkey + window capture (window_capture.zig), created on first use.
    capture: ?*window_capture.Service = null,

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
    };

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
        switch (self.backend) {
            inline else => |b| b.destroy(),
        }
        self.disp.deinit();
        text_mod.destroyPlatformTextSystem(self.text_system);
        self.loop.deinit();
        self.gpa.destroy(self);
    }
};

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
    }
    self.atspi = atspi.Bridge.create(gpa, &self.loop, .fromProcess());
    return self.platformInterface();
}

test {
    std.testing.refAllDecls(@This());
}
