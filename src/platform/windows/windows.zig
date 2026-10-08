//! Windows platform backend (Windows 10/11, x86_64): Win32 windows and input,
//! DirectComposition + D3D11 rendering (src/renderer/d3d11), DirectWrite text
//! (src/text/directwrite.zig), and the desktop-companion surface of
//! docs/DESKTOP_OVERLAY.md (overlay windows, global input, tray icon, foreground app,
//! launch at login).
//!
//!     const plat = try windows.create(gpa, .{});
//!     defer plat.deinit();
//!     plat.run(.{ .ctx = &app, .func = App.onLaunch });
//!
//! Threads:
//! * main: the message loop. Blocks in `MsgWaitForMultipleObjectsEx` until a message,
//!   a posted runnable or the next `dispatchAfter` deadline; nothing polls.
//! * frame pacer: wakes once per vblank (`IDXGIOutput::WaitForVBlank`) only while some
//!   window has requested a frame, and posts one `WM_APP_VSYNC`; otherwise it sleeps on
//!   an event. Windows draw only from `request_frame` callbacks.
//! * input hooks: `WH_KEYBOARD_LL` / `WH_MOUSE_LL` live on their own thread with its own
//!   message loop, so a busy main thread can never make Windows time the hooks out. The
//!   callbacks classify the event, `PostMessage` a packed word to the main thread and
//!   return `CallNextHookEx` immediately (no allocation, no locks).
//! * workers: the dispatcher's background pool.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const input = @import("../../input.zig");
const text_mod = @import("../../text/text.zig");
const image = @import("../../image/image.zig");
const d3d = @import("../../renderer/d3d11/d3d11.zig");
/// Hand-written D3D11 / DXGI bindings (renderer internals; exposed for diagnostics).
pub const d3d11 = d3d;

pub const win32 = @import("win32.zig");
pub const dwrite = @import("dwrite.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const keyboard = @import("keyboard.zig");
pub const window = @import("window.zig");
pub const native_controls = @import("native_controls.zig");
pub const Renderer = @import("../../renderer/d3d11/Renderer.zig");

const w = win32;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.windows);

pub const Window = window.Window;

pub const WM_APP_VSYNC: w.UINT = w.WM_APP + 2;
pub const WM_APP_GLOBAL_INPUT: w.UINT = w.WM_APP + 3;
pub const WM_APP_MOUSE_MOVED: w.UINT = w.WM_APP + 4;
pub const WM_APP_TRAY: w.UINT = w.WM_APP + 5;
pub const WM_APP_FRAME_NOW: w.UINT = w.WM_APP + 6;
const WM_APP_HOOK_RECONFIGURE: w.UINT = w.WM_APP + 7;

var debug_messages = false;

pub const Options = struct {
    /// Background worker threads; null = CPU count.
    worker_threads: ?usize = null,
};

pub const WindowsPlatform = struct {
    gpa: Allocator,
    hinstance: w.HINSTANCE,
    /// Hidden top-level tool window: dispatcher wake-ups, timers, vsync, hook events,
    /// the tray icon's owner, and broadcast messages (setting / display changes).
    hidden: w.HWND,
    disp: dispatcher.WindowsDispatcher,
    text_system: platform.TextSystem,
    callbacks: platform.PlatformCallbacks = .{},
    windows: std.ArrayList(*Window) = .empty,
    quit_requested: bool = false,
    cursor_style: platform.CursorStyle = .arrow,
    cursors: [@typeInfo(platform.CursorStyle).@"enum".field_names.len]?w.HCURSOR = @splat(null),
    appearance: platform.WindowAppearance = .light,
    reduced_motion: bool = false,
    pacer: FramePacer = .{},
    hooks: HookThread = .{},
    global_input_cb: platform.Callback(platform.GlobalInputEvent, void) = .{},
    foreground_cb: platform.Callback(void, void) = .{},
    foreground_hook: ?w.HWINEVENTHOOK = null,
    tray: Tray = .{},
    /// comctl32 v6 activation context (themed common controls without an exe manifest).
    actctx: ?w.HANDLE = null,
    /// Menu item id -> tag for the menu currently shown (tray / context menu).
    menu_tags: std.ArrayList(usize) = .empty,

    pub fn platformInterface(self: *WindowsPlatform) platform.Platform {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn fromPlatform(p: platform.Platform) *WindowsPlatform {
        return @ptrCast(@alignCast(p.ptr));
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
        .startGlobalInputMonitor = startGlobalInputMonitor,
        .stopGlobalInputMonitor = stopGlobalInputMonitor,
        .setPreciseInput = setPreciseInput,
        .inputPermission = inputPermission,
        .requestInputPermission = requestInputPermission,
        .setTrayItem = setTrayItem,
        .foregroundApp = foregroundApp,
        .setForegroundAppCallback = setForegroundAppCallback,
        .setLaunchAtLogin = setLaunchAtLogin,
    };

    fn cast(ptr: *anyopaque) *WindowsPlatform {
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

    // -----------------------------------------------------------------------------------
    // Run loop
    // -----------------------------------------------------------------------------------

    fn run(ptr: *anyopaque, on_launch: platform.Callback(void, void)) void {
        const self = cast(ptr);
        _ = on_launch.call({});
        var msg: w.MSG = undefined;
        while (!self.quit_requested) {
            self.disp.drainMain();
            while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
                if (msg.message == w.WM_QUIT) {
                    self.quit_requested = true;
                    break;
                }
                if (debug_messages) {
                    var cls: [64]u16 = undefined;
                    var cls8: [128]u8 = undefined;
                    const n = if (msg.hwnd) |h| w.GetClassNameW(h, &cls, cls.len) else 0;
                    std.debug.print("msg 0x{x} class {s}\n", .{ msg.message, w.wideToUtf8Buf(&cls8, cls[0..@intCast(@max(n, 0))]) });
                }
                _ = w.TranslateMessage(&msg);
                _ = w.DispatchMessageW(&msg);
                if (self.quit_requested) break;
            }
            if (self.quit_requested) break;
            // Timers last: the messages above may have scheduled new ones.
            const timeout = self.disp.runTimers();
            if (self.quit_requested) break;
            if (timeout == 0) continue;
            // Sleep until input, a posted message (runnables, vsync, hooks) or the next timer.
            _ = w.MsgWaitForMultipleObjectsEx(0, null, timeout, w.QS_ALLINPUT, w.MWMO_INPUTAVAILABLE);
        }
        if (self.callbacks.quit) |f| f(self.callbacks.ctx);
    }

    fn quit(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.quit_requested = true;
        _ = w.PostMessageW(self.hidden, w.WM_NULL, 0, 0);
    }

    fn activate(ptr: *anyopaque, _: bool) void {
        const self = cast(ptr);
        for (self.windows.items) |win| if (win.kind != .overlay and win.visible) {
            _ = w.SetForegroundWindow(win.hwnd);
            return;
        };
    }

    fn openWindow(ptr: *anyopaque, params: platform.WindowParams) anyerror!platform.Window {
        const self = cast(ptr);
        const win = try Window.create(self, params);
        return win.platformWindow();
    }

    pub fn removeWindow(self: *WindowsPlatform, win: *Window) void {
        for (self.windows.items, 0..) |x, i| if (x == win) {
            _ = self.windows.swapRemove(i);
            break;
        };
        self.updateHooks();
    }

    // -----------------------------------------------------------------------------------
    // Hidden window
    // -----------------------------------------------------------------------------------

    fn hiddenProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
        const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
        if (raw == 0) {
            if (msg == w.WM_NCCREATE) {
                const cs: *const w.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
            }
            return w.DefWindowProcW(hwnd, msg, wparam, lparam);
        }
        const self: *WindowsPlatform = @ptrFromInt(@as(usize, @bitCast(raw)));
        switch (msg) {
            dispatcher.WM_APP_WAKE => {
                self.disp.drainMain();
                return 0;
            },
            w.WM_TIMER => if (wparam == dispatcher.modal_timer_id) {
                self.disp.onModalTimer();
                return 0;
            },
            WM_APP_VSYNC => {
                self.onVsync();
                return 0;
            },
            WM_APP_GLOBAL_INPUT => {
                self.onGlobalInput(wparam, lparam);
                return 0;
            },
            WM_APP_MOUSE_MOVED => {
                self.onGlobalMouseMoved();
                return 0;
            },
            WM_APP_TRAY => {
                self.onTrayMessage(wparam, lparam);
                return 0;
            },
            w.WM_SETTINGCHANGE => {
                self.onSettingChange(lparam);
                return 0;
            },
            w.WM_DISPLAYCHANGE => {
                for (self.windows.items) |win| win.onDisplayChange();
                return 0;
            },
            w.WM_ENTERMENULOOP => self.disp.enterModal(),
            w.WM_EXITMENULOOP => self.disp.exitModal(),
            else => if (msg == self.tray.taskbar_created and msg != 0) {
                self.tray.readd(self);
                return 0;
            },
        }
        return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    // -----------------------------------------------------------------------------------
    // Frame pacing
    // -----------------------------------------------------------------------------------

    /// A window wants a `request_frame` at the next vblank.
    pub fn wantFrame(self: *WindowsPlatform) void {
        self.pacer.want(self.hidden);
    }

    fn onVsync(self: *WindowsPlatform) void {
        self.pacer.posted.store(false, .release);
        // Callbacks may close windows (mutating the list): iterate by index.
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            const win = self.windows.items[i];
            if (!win.frame_requested) continue;
            win.frame_requested = false;
            win.fireRequestFrame(false);
        }
        var any = false;
        for (self.windows.items) |win| any = any or win.frame_requested;
        if (!any) self.pacer.wanted.store(false, .release);
    }

    // -----------------------------------------------------------------------------------
    // Appearance, displays, cursors
    // -----------------------------------------------------------------------------------

    fn onSettingChange(self: *WindowsPlatform, lparam: w.LPARAM) void {
        if (lparam != 0) {
            const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (!std.mem.eql(u16, std.mem.span(name), L("ImmersiveColorSet"))) {
                self.reduced_motion = readReducedMotion();
                return;
            }
        }
        const next = readAppearance();
        self.reduced_motion = readReducedMotion();
        if (next == self.appearance) return;
        self.appearance = next;
        self.tray.refreshIcon(self);
        for (self.windows.items) |win| win.onAppearanceChanged();
    }

    fn windowAppearance(ptr: *anyopaque) platform.WindowAppearance {
        return cast(ptr).appearance;
    }
    fn prefersReducedMotion(ptr: *anyopaque) bool {
        return cast(ptr).reduced_motion;
    }

    fn displays(_: *anyopaque, out: []platform.Display) usize {
        var ctx: EnumCtx = .{ .out = out };
        _ = w.EnumDisplayMonitors(null, null, EnumCtx.cb, @bitCast(@intFromPtr(&ctx)));
        return ctx.n;
    }

    const EnumCtx = struct {
        out: []platform.Display,
        n: usize = 0,
        fn cb(mon: w.HMONITOR, _: ?w.HDC, _: *w.RECT, data: w.LPARAM) callconv(w.WINAPI) w.BOOL {
            const ctx: *EnumCtx = @ptrFromInt(@as(usize, @bitCast(data)));
            if (ctx.n >= ctx.out.len) return w.FALSE;
            if (displayInfo(mon)) |d| {
                ctx.out[ctx.n] = d;
                ctx.n += 1;
            }
            return w.TRUE;
        }
    };

    fn setCursorStyle(ptr: *anyopaque, style: platform.CursorStyle) void {
        const self = cast(ptr);
        self.cursor_style = style;
        // Apply now when the pointer is over one of our windows (WM_SETCURSOR keeps it).
        var pt: w.POINT = .{};
        if (w.GetCursorPos(&pt) == 0) return;
        const under = w.WindowFromPoint(pt) orelse return;
        for (self.windows.items) |win| if (win.hwnd == under) {
            _ = w.SetCursor(self.cursorHandle());
            return;
        };
    }

    pub fn cursorHandle(self: *WindowsPlatform) ?w.HCURSOR {
        const style = self.cursor_style;
        if (style == .none) return null;
        const slot = &self.cursors[@backingInt(style)];
        if (slot.* == null) {
            const id: usize = switch (style) {
                .arrow, .context_menu, .drag_copy => w.IDC_ARROW,
                .ibeam => w.IDC_IBEAM,
                .crosshair => w.IDC_CROSS,
                .closed_hand, .open_hand => w.IDC_SIZEALL,
                .pointing_hand, .drag_link => w.IDC_HAND,
                .resize_left, .resize_right, .resize_left_right, .resize_column => w.IDC_SIZEWE,
                .resize_up, .resize_down, .resize_up_down, .resize_row => w.IDC_SIZENS,
                .operation_not_allowed => w.IDC_NO,
                .none => unreachable,
            };
            slot.* = w.LoadCursorW(null, id);
        }
        return slot.*;
    }

    // -----------------------------------------------------------------------------------
    // Clipboard, shell
    // -----------------------------------------------------------------------------------

    fn writeClipboard(ptr: *anyopaque, text: []const u8) void {
        const self = cast(ptr);
        const wide = w.utf8ToWide(self.gpa, text) catch return;
        defer self.gpa.free(wide);
        const bytes = (wide.len + 1) * 2;
        const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes) orelse return;
        const dst: [*]u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse {
            _ = w.GlobalFree(mem);
            return;
        }));
        @memcpy(dst[0 .. wide.len + 1], wide.ptr[0 .. wide.len + 1]);
        _ = w.GlobalUnlock(mem);
        if (w.OpenClipboard(self.hidden) == 0) {
            _ = w.GlobalFree(mem);
            return;
        }
        defer _ = w.CloseClipboard();
        _ = w.EmptyClipboard();
        if (w.SetClipboardData(w.CF_UNICODETEXT, mem) == null) _ = w.GlobalFree(mem);
    }

    fn readClipboard(ptr: *anyopaque, gpa: Allocator) ?[]u8 {
        const self = cast(ptr);
        if (w.IsClipboardFormatAvailable(w.CF_UNICODETEXT) == 0) return null;
        if (w.OpenClipboard(self.hidden) == 0) return null;
        defer _ = w.CloseClipboard();
        const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return null;
        const p: [*]const u16 = @ptrCast(@alignCast(w.GlobalLock(h) orelse return null));
        defer _ = w.GlobalUnlock(h);
        const max = w.GlobalSize(h) / 2;
        var n: usize = 0;
        while (n < max and p[n] != 0) n += 1;
        var out = w.wideToUtf8Alloc(gpa, p[0..n]) catch return null;
        // CRLF -> LF (zpui text is LF-only).
        var j: usize = 0;
        for (out, 0..) |ch, i| {
            if (ch == '\r' and i + 1 < out.len and out[i + 1] == '\n') continue;
            out[j] = ch;
            j += 1;
        }
        out = gpa.realloc(out, j) catch out[0..j];
        return out;
    }

    fn readClipboardImage(ptr: *anyopaque, gpa: Allocator) ?platform.ClipboardImage {
        const self = cast(ptr);
        const fmt = w.RegisterClipboardFormatW(L("PNG"));
        if (fmt == 0 or w.IsClipboardFormatAvailable(fmt) == 0) return null;
        if (w.OpenClipboard(self.hidden) == 0) return null;
        defer _ = w.CloseClipboard();
        const h = w.GetClipboardData(fmt) orelse return null;
        const p: [*]const u8 = @ptrCast(w.GlobalLock(h) orelse return null);
        defer _ = w.GlobalUnlock(h);
        const bytes = gpa.dupe(u8, p[0..w.GlobalSize(h)]) catch return null;
        return .{ .format = .png, .bytes = bytes };
    }

    fn openUrl(ptr: *anyopaque, url: []const u8) void {
        const self = cast(ptr);
        const wide = w.utf8ToWide(self.gpa, url) catch return;
        defer self.gpa.free(wide);
        _ = w.ShellExecuteW(null, L("open"), wide.ptr, null, null, w.SW_SHOWNORMAL);
    }

    fn revealPath(ptr: *anyopaque, path: []const u8) void {
        const self = cast(ptr);
        const args = std.fmt.allocPrint(self.gpa, "/select,\"{s}\"", .{path}) catch return;
        defer self.gpa.free(args);
        const wide = w.utf8ToWide(self.gpa, args) catch return;
        defer self.gpa.free(wide);
        _ = w.ShellExecuteW(null, L("open"), L("explorer.exe"), wide.ptr, null, w.SW_SHOWNORMAL);
    }

    // -----------------------------------------------------------------------------------
    // Global input monitor (docs/DESKTOP_OVERLAY.md §2)
    // -----------------------------------------------------------------------------------

    fn startGlobalInputMonitor(ptr: *anyopaque, cb: platform.Callback(platform.GlobalInputEvent, void)) platform.InputMonitorStatus {
        const self = cast(ptr);
        self.global_input_cb = cb;
        hook_shared.monitor.store(true, .release);
        self.updateHooks();
        return if (self.hooks.running()) .ok else .unsupported;
    }

    fn stopGlobalInputMonitor(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.global_input_cb = .{};
        hook_shared.monitor.store(false, .release);
        self.updateHooks();
    }

    /// The low-level hooks already see every key with its scan code: nothing to switch.
    fn setPreciseInput(_: *anyopaque, _: bool) void {}

    /// Windows needs no permission for low-level hooks.
    fn inputPermission(_: *anyopaque) platform.InputPermission {
        return .not_applicable;
    }
    fn requestInputPermission(_: *anyopaque) void {}

    /// Start / reconfigure / stop the hook thread for the current needs: the global
    /// monitor and overlay windows whose input region follows the pointer.
    pub fn updateHooks(self: *WindowsPlatform) void {
        var track = false;
        for (self.windows.items) |win| track = track or win.needsPointerTracking();
        hook_shared.track_moves.store(track, .release);
        const want = hook_shared.monitor.load(.acquire) or track;
        if (want) self.hooks.start(self.hidden) else self.hooks.stop();
        self.hooks.reconfigure();
    }

    fn onGlobalInput(self: *WindowsPlatform, wparam: w.WPARAM, lparam: w.LPARAM) void {
        const kind: platform.GlobalInputKind = @fromBackingInt(@intCast(@as(u3, @truncate(wparam))));
        const key: platform.GlobalKeyClass = @fromBackingInt(@intCast(@as(u4, @truncate(wparam >> 3))));
        const key_x: f32 = @as(f32, @floatFromInt(@as(u10, @truncate(wparam >> 8)))) / 1000.0;
        const ts = self.disp.qpcToNs(@intCast(@as(u64, @bitCast(@as(i64, lparam)))));
        _ = self.global_input_cb.call(.{ .kind = kind, .key = key, .key_x = std.math.clamp(key_x, 0, 1), .timestamp_ns = ts });
    }

    fn onGlobalMouseMoved(self: *WindowsPlatform) void {
        hook_shared.move_pending.store(false, .release);
        const packed_pt = hook_shared.last_move.load(.acquire);
        const pt: w.POINT = .{ .x = @bitCast(@as(u32, @truncate(packed_pt))), .y = @bitCast(@as(u32, @truncate(packed_pt >> 32))) };
        for (self.windows.items) |win| win.updatePointerTransparency(pt);
    }

    // -----------------------------------------------------------------------------------
    // Foreground application (§4)
    // -----------------------------------------------------------------------------------

    fn foregroundApp(_: *anyopaque, buf: []u8) ?platform.ForegroundApp {
        const fg = w.GetForegroundWindow() orelse return null;
        var pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(fg, &pid);
        if (pid == 0) return null;
        const proc = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, w.FALSE, pid) orelse return null;
        defer _ = w.CloseHandle(proc);
        var path: [1024]u16 = undefined;
        var len: w.DWORD = path.len;
        if (w.QueryFullProcessImageNameW(proc, 0, &path, &len) == 0 or len == 0) return null;
        const full = path[0..len];
        var base_start: usize = 0;
        for (full, 0..) |ch, i| if (ch == '\\' or ch == '/') {
            base_start = i + 1;
        };
        const base = full[base_start..];
        // id = executable basename ("Code.exe"); name = its FileDescription when present.
        const id = w.wideToUtf8Buf(buf, base);
        const rest = buf[id.len..];
        path[len] = 0;
        const name = fileDescription(path[0..len :0], rest) orelse blk: {
            var stem = base;
            if (stem.len > 4 and std.ascii.eqlIgnoreCase(asciiTail(stem[stem.len - 4 ..]), ".exe")) stem = stem[0 .. stem.len - 4];
            break :blk w.wideToUtf8Buf(rest, stem);
        };
        return .{ .id = id, .name = name };
    }

    fn setForegroundAppCallback(ptr: *anyopaque, cb: platform.Callback(void, void)) void {
        const self = cast(ptr);
        self.foreground_cb = cb;
        foreground_target = self;
        if (cb.func != null and self.foreground_hook == null) {
            // Out-of-context: delivered through this (main) thread's message loop.
            self.foreground_hook = w.SetWinEventHook(w.EVENT_SYSTEM_FOREGROUND, w.EVENT_SYSTEM_FOREGROUND, null, onForegroundEvent, 0, 0, w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS);
        } else if (cb.func == null) if (self.foreground_hook) |h| {
            _ = w.UnhookWinEvent(h);
            self.foreground_hook = null;
        };
    }

    // -----------------------------------------------------------------------------------
    // Launch at login (§5)
    // -----------------------------------------------------------------------------------

    fn setLaunchAtLogin(ptr: *anyopaque, app_id: []const u8, exe_path: []const u8, on: bool) anyerror!void {
        const self = cast(ptr);
        var key: ?w.HKEY = null;
        if (w.RegCreateKeyExW(w.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Run"), 0, null, 0, w.KEY_SET_VALUE, null, &key, null) != w.ERROR_SUCCESS)
            return error.RegistryUnavailable;
        defer _ = w.RegCloseKey(key.?);
        const name = try w.utf8ToWide(self.gpa, app_id);
        defer self.gpa.free(name);
        if (!on) {
            const r = w.RegDeleteValueW(key.?, name.ptr);
            if (r != w.ERROR_SUCCESS and r != 2) return error.RegistryWriteFailed; // 2 = not found
            return;
        }
        const cmd = try std.fmt.allocPrint(self.gpa, "\"{s}\"", .{exe_path});
        defer self.gpa.free(cmd);
        const value = try w.utf8ToWide(self.gpa, cmd);
        defer self.gpa.free(value);
        const bytes: [*]const u8 = @ptrCast(value.ptr);
        if (w.RegSetValueExW(key.?, name.ptr, 0, w.REG_SZ, bytes, @intCast((value.len + 1) * 2)) != w.ERROR_SUCCESS)
            return error.RegistryWriteFailed;
    }

    // -----------------------------------------------------------------------------------
    // Tray (§3) + native menus
    // -----------------------------------------------------------------------------------

    fn setTrayItem(ptr: *anyopaque, item: ?platform.TrayItem) anyerror!void {
        const self = cast(ptr);
        if (item) |it| try self.tray.set(self, it) else self.tray.remove(self);
    }

    fn onTrayMessage(self: *WindowsPlatform, wparam: w.WPARAM, lparam: w.LPARAM) void {
        const event: w.UINT = w.loword(lparam);
        switch (event) {
            w.WM_CONTEXTMENU, w.NIN_SELECT, w.NIN_KEYSELECT, w.WM_LBUTTONUP, w.WM_RBUTTONUP => {
                // NOTIFYICON_VERSION_4: wParam carries the anchor point in screen coordinates.
                const x = w.xParam(@bitCast(wparam));
                const y = w.yParam(@bitCast(wparam));
                self.tray.showMenu(self, x, y);
            },
            else => {},
        }
    }

    /// Append `items` to `menu` (recursively); item ids index `menu_tags`.
    pub fn buildMenu(self: *WindowsPlatform, menu: w.HMENU, items: []const platform.MenuItem) void {
        for (items) |item| switch (item) {
            .separator => _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null),
            .action => |a| {
                self.menu_tags.append(self.gpa, a.tag) catch return;
                var buf: [256]u16 = undefined;
                var flags: w.UINT = w.MF_STRING;
                if (a.checked) flags |= w.MF_CHECKED;
                if (a.disabled) flags |= w.MF_GRAYED;
                _ = w.AppendMenuW(menu, flags, self.menu_tags.items.len, w.wideBuf(&buf, a.name).ptr);
            },
            .submenu => |m| {
                const sub = w.CreatePopupMenu() orelse continue;
                self.buildMenu(sub, m.items);
                var buf: [256]u16 = undefined;
                _ = w.AppendMenuW(menu, w.MF_POPUP | (if (m.disabled) w.MF_GRAYED else 0), @intFromPtr(sub), w.wideBuf(&buf, m.name).ptr);
            },
            .system_menu => {},
        };
    }

    /// Show `menu` at screen `x`,`y` owned by `owner` and return the chosen id (0 = none).
    pub fn trackMenu(self: *WindowsPlatform, menu: w.HMENU, owner: w.HWND, x: i32, y: i32, flags: w.UINT) usize {
        // Popup menus close on outside clicks only while their owner is foreground.
        _ = w.SetForegroundWindow(owner);
        self.disp.enterModal();
        defer self.disp.exitModal();
        const r = w.TrackPopupMenu(menu, flags | w.TPM_RETURNCMD | w.TPM_NONOTIFY | w.TPM_RIGHTBUTTON, x, y, 0, owner, null);
        _ = w.PostMessageW(owner, w.WM_NULL, 0, 0);
        return @intCast(@max(r, 0));
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self = cast(ptr);
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].destroyNow();
        self.windows.deinit(self.gpa);
        hook_shared.monitor.store(false, .release);
        self.hooks.stop();
        self.pacer.stop();
        self.tray.remove(self);
        if (self.foreground_hook) |h| _ = w.UnhookWinEvent(h);
        if (foreground_target == self) foreground_target = null;
        self.menu_tags.deinit(self.gpa);
        self.disp.deinit();
        text_mod.destroyPlatformTextSystem(self.text_system);
        _ = w.DestroyWindow(self.hidden);
        self.gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------

fn asciiTail(s: []const u16) []const u8 {
    const S = struct {
        threadlocal var buf: [8]u8 = undefined;
    };
    for (s, 0..) |ch, i| S.buf[i] = if (ch < 0x80) @intCast(ch) else '?';
    return S.buf[0..s.len];
}

/// The executable's FileDescription version resource ("Visual Studio Code"), into `out`.
fn fileDescription(path: [:0]const u16, out: []u8) ?[]u8 {
    var handle: w.DWORD = 0;
    const size = w.GetFileVersionInfoSizeW(path.ptr, &handle);
    if (size == 0 or size > 1 << 20) return null;
    const buf = std.heap.page_allocator.alloc(u8, size) catch return null;
    defer std.heap.page_allocator.free(buf);
    if (w.GetFileVersionInfoW(path.ptr, 0, size, buf.ptr) == 0) return null;
    var trans: ?*anyopaque = null;
    var trans_len: w.UINT = 0;
    var lang: u32 = 0x040904B0; // en-US, Unicode
    if (w.VerQueryValueW(buf.ptr, L("\\VarFileInfo\\Translation"), &trans, &trans_len) != 0 and trans_len >= 4) {
        const t: [*]const u16 = @ptrCast(@alignCast(trans.?));
        lang = (@as(u32, t[0]) << 16) | t[1];
    }
    var q: [64]u8 = undefined;
    const query = std.fmt.bufPrint(&q, "\\StringFileInfo\\{x:0>8}\\FileDescription", .{lang}) catch return null;
    var qw: [64]u16 = undefined;
    var value: ?*anyopaque = null;
    var value_len: w.UINT = 0;
    if (w.VerQueryValueW(buf.ptr, w.wideBuf(&qw, query).ptr, &value, &value_len) == 0 or value_len <= 1) return null;
    const s: [*]const u16 = @ptrCast(@alignCast(value.?));
    var n: usize = 0;
    while (n < value_len and s[n] != 0) n += 1;
    if (n == 0) return null;
    return w.wideToUtf8Buf(out, s[0..n]);
}

var foreground_target: ?*WindowsPlatform = null;

fn onForegroundEvent(_: ?w.HWINEVENTHOOK, _: w.DWORD, _: ?w.HWND, _: w.LONG, _: w.LONG, _: w.DWORD, _: w.DWORD) callconv(w.WINAPI) void {
    const self = foreground_target orelse return;
    _ = self.foreground_cb.call({});
}

/// Registry: HKCU ...\Themes\Personalize `AppsUseLightTheme` (missing = light).
pub fn readAppearance() platform.WindowAppearance {
    var value: w.DWORD = 1;
    var size: w.DWORD = @sizeOf(w.DWORD);
    _ = w.RegGetValueW(w.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("AppsUseLightTheme"), w.RRF_RT_REG_DWORD, null, &value, &size);
    return if (value == 0) .dark else .light;
}

/// The taskbar / tray follows `SystemUsesLightTheme` (separate from the apps' theme).
fn systemUsesDarkTheme() bool {
    var value: w.DWORD = 0;
    var size: w.DWORD = @sizeOf(w.DWORD);
    _ = w.RegGetValueW(w.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("SystemUsesLightTheme"), w.RRF_RT_REG_DWORD, null, &value, &size);
    return value == 0;
}

fn readReducedMotion() bool {
    var enabled: w.BOOL = w.TRUE;
    _ = w.SystemParametersInfoW(w.SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0);
    return enabled == 0;
}

pub fn monitorDpi(mon: w.HMONITOR) u32 {
    var x: w.UINT = 96;
    var y: w.UINT = 96;
    if (w.GetDpiForMonitor(mon, w.MDT_EFFECTIVE_DPI, &x, &y) < 0) return 96;
    return x;
}

/// A display's id: the N of `\\.\DISPLAYN` (stable for a given output configuration).
pub fn displayId(info: *const w.MONITORINFOEXW) u32 {
    var n: u32 = 0;
    var any = false;
    for (info.szDevice) |ch| {
        if (ch == 0) break;
        if (ch >= '0' and ch <= '9') {
            n = n * 10 + (ch - '0');
            any = true;
        } else if (any) n = 0;
    }
    return n;
}

pub fn displayInfo(mon: w.HMONITOR) ?platform.Display {
    var info: w.MONITORINFOEXW = .{};
    if (w.GetMonitorInfoW(mon, &info) == 0) return null;
    const scale = @as(f32, @floatFromInt(monitorDpi(mon))) / 96.0;
    return .{
        .id = displayId(&info),
        .bounds = rectToLogical(info.rcMonitor, scale),
        .visible_bounds = rectToLogical(info.rcWork, scale),
        .scale_factor = scale,
        .primary = info.dwFlags & w.MONITORINFOF_PRIMARY != 0,
    };
}

pub fn rectToLogical(r: w.RECT, scale: f32) platform.Bounds {
    return .{
        .origin = .{ .x = @as(f32, @floatFromInt(r.left)) / scale, .y = @as(f32, @floatFromInt(r.top)) / scale },
        .size = .{ .width = @as(f32, @floatFromInt(r.width())) / scale, .height = @as(f32, @floatFromInt(r.height())) / scale },
    };
}

/// The monitor with display id `id`, or null.
pub fn monitorById(id: u32) ?w.HMONITOR {
    const Ctx = struct {
        id: u32,
        found: ?w.HMONITOR = null,
        fn cb(mon: w.HMONITOR, _: ?w.HDC, _: *w.RECT, data: w.LPARAM) callconv(w.WINAPI) w.BOOL {
            const ctx: *@This() = @ptrFromInt(@as(usize, @bitCast(data)));
            var info: w.MONITORINFOEXW = .{};
            if (w.GetMonitorInfoW(mon, &info) != 0 and displayId(&info) == ctx.id) {
                ctx.found = mon;
                return w.FALSE;
            }
            return w.TRUE;
        }
    };
    var ctx: Ctx = .{ .id = id };
    _ = w.EnumDisplayMonitors(null, null, Ctx.cb, @bitCast(@intFromPtr(&ctx)));
    return ctx.found;
}

pub fn primaryMonitor() ?w.HMONITOR {
    return w.MonitorFromPoint(.{ .x = 0, .y = 0 }, w.MONITOR_DEFAULTTOPRIMARY);
}

// ---------------------------------------------------------------------------------------
// Frame pacer thread
// ---------------------------------------------------------------------------------------

const FramePacer = struct {
    thread: ?std.Thread = null,
    event: ?w.HANDLE = null,
    running: std.atomic.Value(bool) = .init(false),
    wanted: std.atomic.Value(bool) = .init(false),
    posted: std.atomic.Value(bool) = .init(false),
    target: ?w.HWND = null,

    fn want(p: *FramePacer, target: w.HWND) void {
        if (p.thread == null) p.startThread(target) catch {
            // No pacer thread: fall back to a timer-free immediate tick.
            _ = w.PostMessageW(target, WM_APP_VSYNC, 0, 0);
            return;
        };
        if (!p.wanted.swap(true, .acq_rel)) _ = w.SetEvent(p.event.?);
    }

    fn startThread(p: *FramePacer, target: w.HWND) !void {
        p.event = w.CreateEventW(null, w.TRUE, w.FALSE, null) orelse return error.EventFailed;
        p.target = target;
        p.running.store(true, .release);
        p.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, threadMain, .{p}) catch |e| {
            _ = w.CloseHandle(p.event.?);
            p.event = null;
            p.running.store(false, .release);
            return e;
        };
    }

    fn stop(p: *FramePacer) void {
        const t = p.thread orelse return;
        p.running.store(false, .release);
        _ = w.SetEvent(p.event.?);
        t.join();
        _ = w.CloseHandle(p.event.?);
        p.thread = null;
        p.event = null;
    }

    fn threadMain(p: *FramePacer) void {
        _ = w.SetThreadPriority(w.GetCurrentThread(), 2); // THREAD_PRIORITY_HIGHEST
        const output = primaryOutput();
        defer w.release(output);
        while (p.running.load(.acquire)) {
            _ = w.WaitForSingleObject(p.event.?, w.INFINITE);
            while (p.running.load(.acquire) and p.wanted.load(.acquire)) {
                waitVblank(output);
                if (!p.posted.swap(true, .acq_rel)) {
                    if (w.PostMessageW(p.target.?, WM_APP_VSYNC, 0, 0) == 0) p.posted.store(false, .release);
                }
            }
            _ = w.ResetEvent(p.event.?);
            // A request may have raced the reset: keep going if so.
            if (p.wanted.load(.acquire)) _ = w.SetEvent(p.event.?);
        }
    }

    fn primaryOutput() ?*d3d.IDXGIOutput {
        var raw: ?*anyopaque = null;
        if (d3d.CreateDXGIFactory1(&d3d.IDXGIFactory2.iid1, &raw) < 0) return null;
        const factory: *d3d.IDXGIFactory2 = @ptrCast(@alignCast(raw.?));
        defer w.release(factory);
        var adapter: ?*d3d.IDXGIAdapter = null;
        if (factory.vtbl.EnumAdapters(factory, 0, &adapter) < 0) return null;
        defer w.release(adapter);
        var output: ?*d3d.IDXGIOutput = null;
        if (adapter.?.vtbl.EnumOutputs(adapter.?, 0, &output) < 0) return null;
        return output;
    }

    fn waitVblank(output: ?*d3d.IDXGIOutput) void {
        const start = w.GetTickCount64();
        var ok = false;
        if (output) |o| ok = o.vtbl.WaitForVBlank(o) >= 0;
        if (!ok) ok = w.DwmFlush() >= 0;
        // Some drivers (basic display adapter, remote sessions) return immediately:
        // never spin, fall back to ~60 Hz.
        if (!ok or w.GetTickCount64() - start < 1) w.Sleep(15);
    }
};

// ---------------------------------------------------------------------------------------
// Input hook thread
// ---------------------------------------------------------------------------------------

/// State shared with the hook procedures (which take no context pointer).
const hook_shared = struct {
    var target: std.atomic.Value(usize) = .init(0);
    var monitor: std.atomic.Value(bool) = .init(false);
    var track_moves: std.atomic.Value(bool) = .init(false);
    var move_pending: std.atomic.Value(bool) = .init(false);
    var last_move: std.atomic.Value(u64) = .init(0);
    /// Hook thread only: keys currently down (auto-repeat filter).
    var keys_down: [256]bool = @splat(false);
    var keyboard_hook: ?w.HHOOK = null;
    var mouse_hook: ?w.HHOOK = null;
    /// The keyboard hook is in place whenever the monitor wants one.
    var keyboard_hook_installed: std.atomic.Value(bool) = .init(false);
};

fn qpcNow() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

fn postGlobal(kind: platform.GlobalInputKind, key: platform.GlobalKeyClass, key_x: f32) void {
    const target = hook_shared.target.load(.acquire);
    if (target == 0) return;
    const x: usize = @intFromFloat(std.math.clamp(key_x, 0, 1) * 1000);
    const packed_word: usize = @backingInt(kind) | (@as(usize, @backingInt(key)) << 3) | (x << 8);
    _ = w.PostMessageW(@ptrFromInt(target), WM_APP_GLOBAL_INPUT, packed_word, @intCast(qpcNow()));
}

fn keyboardHookProc(code: i32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (code == w.HC_ACTION and hook_shared.monitor.load(.monotonic)) {
        const kb: *const w.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const up = wparam == w.WM_KEYUP or wparam == w.WM_SYSKEYUP;
        const vk = kb.vkCode & 0xff;
        const was_down = hook_shared.keys_down[vk];
        hook_shared.keys_down[vk] = !up;
        // Only edges: auto-repeat would read as frantic typing.
        if (up or !was_down) {
            const ext = kb.flags & w.LLKHF_EXTENDED != 0;
            const info = keyboard.globalKey(vk, kb.scanCode, ext);
            postGlobal(if (up) .key_up else .key_down, info.class, info.x);
        }
    }
    return w.CallNextHookEx(null, code, wparam, lparam);
}

fn mouseHookProc(code: i32, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (code == w.HC_ACTION) {
        const ms: *const w.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const msg: w.UINT = @truncate(wparam);
        if (msg == w.WM_MOUSEMOVE) {
            if (hook_shared.track_moves.load(.monotonic)) {
                const p: u64 = @as(u64, @as(u32, @bitCast(ms.pt.x))) | (@as(u64, @as(u32, @bitCast(ms.pt.y))) << 32);
                hook_shared.last_move.store(p, .release);
                if (!hook_shared.move_pending.swap(true, .acq_rel)) {
                    const target = hook_shared.target.load(.acquire);
                    if (target != 0) _ = w.PostMessageW(@ptrFromInt(target), WM_APP_MOUSE_MOVED, 0, 0);
                }
            }
        } else if (hook_shared.monitor.load(.monotonic)) {
            const kind: ?platform.GlobalInputKind = switch (msg) {
                w.WM_LBUTTONDOWN, w.WM_RBUTTONDOWN, w.WM_MBUTTONDOWN, w.WM_XBUTTONDOWN => .mouse_down,
                w.WM_LBUTTONUP, w.WM_RBUTTONUP, w.WM_MBUTTONUP, w.WM_XBUTTONUP => .mouse_up,
                w.WM_MOUSEWHEEL, w.WM_MOUSEHWHEEL => .scroll,
                else => null,
            };
            if (kind) |k| postGlobal(k, .other, 0.5);
        }
    }
    return w.CallNextHookEx(null, code, wparam, lparam);
}

const HookThread = struct {
    thread: ?std.Thread = null,
    thread_id: std.atomic.Value(u32) = .init(0),
    ready: ?w.HANDLE = null,

    fn running(h: *const HookThread) bool {
        return h.thread != null and hook_shared.keyboard_hook_installed.load(.acquire);
    }

    fn start(h: *HookThread, target: w.HWND) void {
        hook_shared.target.store(@intFromPtr(target), .release);
        if (h.thread != null) return;
        h.ready = w.CreateEventW(null, w.TRUE, w.FALSE, null);
        h.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, threadMain, .{h}) catch {
            if (h.ready) |r| _ = w.CloseHandle(r);
            h.ready = null;
            return;
        };
        // Wait until the thread's queue exists (PostThreadMessage needs it).
        if (h.ready) |r| _ = w.WaitForSingleObject(r, 2000);
    }

    fn reconfigure(h: *HookThread) void {
        const id = h.thread_id.load(.acquire);
        if (id != 0) _ = w.PostThreadMessageW(id, WM_APP_HOOK_RECONFIGURE, 0, 0);
    }

    fn stop(h: *HookThread) void {
        const t = h.thread orelse return;
        const id = h.thread_id.load(.acquire);
        if (id != 0) _ = w.PostThreadMessageW(id, w.WM_QUIT, 0, 0);
        t.join();
        h.thread = null;
        h.thread_id.store(0, .release);
        if (h.ready) |r| _ = w.CloseHandle(r);
        h.ready = null;
    }

    fn apply() void {
        const module = w.GetModuleHandleW(null);
        const want_keys = hook_shared.monitor.load(.acquire);
        const want_mouse = want_keys or hook_shared.track_moves.load(.acquire);
        if (want_keys and hook_shared.keyboard_hook == null) {
            hook_shared.keys_down = @splat(false);
            hook_shared.keyboard_hook = w.SetWindowsHookExW(w.WH_KEYBOARD_LL, keyboardHookProc, module, 0);
        } else if (!want_keys) if (hook_shared.keyboard_hook) |k| {
            _ = w.UnhookWindowsHookEx(k);
            hook_shared.keyboard_hook = null;
        };
        if (want_mouse and hook_shared.mouse_hook == null) {
            hook_shared.mouse_hook = w.SetWindowsHookExW(w.WH_MOUSE_LL, mouseHookProc, module, 0);
        } else if (!want_mouse) if (hook_shared.mouse_hook) |m| {
            _ = w.UnhookWindowsHookEx(m);
            hook_shared.mouse_hook = null;
        };
        hook_shared.keyboard_hook_installed.store(!want_keys or hook_shared.keyboard_hook != null, .release);
    }

    fn threadMain(h: *HookThread) void {
        var msg: w.MSG = undefined;
        // Create the message queue before announcing the thread id.
        _ = w.PeekMessageW(&msg, null, w.WM_USER, w.WM_USER, 0);
        h.thread_id.store(w.GetCurrentThreadId(), .release);
        // Low-level hook callbacks run on this thread: keep it responsive.
        _ = w.SetThreadPriority(w.GetCurrentThread(), 15); // THREAD_PRIORITY_TIME_CRITICAL
        apply();
        if (h.ready) |r| _ = w.SetEvent(r);
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            if (msg.hwnd == null and msg.message == WM_APP_HOOK_RECONFIGURE) {
                apply();
                continue;
            }
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        if (hook_shared.keyboard_hook) |k| _ = w.UnhookWindowsHookEx(k);
        if (hook_shared.mouse_hook) |m| _ = w.UnhookWindowsHookEx(m);
        hook_shared.keyboard_hook = null;
        hook_shared.mouse_hook = null;
        hook_shared.keyboard_hook_installed.store(false, .release);
    }
};

// ---------------------------------------------------------------------------------------
// Tray icon
// ---------------------------------------------------------------------------------------

const Tray = struct {
    added: bool = false,
    icon: ?w.HICON = null,
    /// Owned copies of the current item (re-adding after Explorer restarts, dark/light).
    png: []u8 = &.{},
    template: bool = true,
    tooltip: [128]u16 = @splat(0),
    menu: std.ArrayList(platform.MenuItem) = .empty,
    arena: ?std.heap.ArenaAllocator = null,
    taskbar_created: w.UINT = 0,

    fn set(t: *Tray, plat: *WindowsPlatform, item: platform.TrayItem) !void {
        if (t.taskbar_created == 0) t.taskbar_created = w.RegisterWindowMessageW(L("TaskbarCreated"));
        // Copy everything (menus are re-read on every click).
        if (t.arena) |*a| a.deinit();
        t.arena = std.heap.ArenaAllocator.init(plat.gpa);
        const arena = t.arena.?.allocator();
        t.png = try arena.dupe(u8, item.icon_png);
        t.template = item.template;
        _ = w.wideBuf(&t.tooltip, item.tooltip);
        t.menu = .empty;
        try t.menu.appendSlice(arena, try copyMenu(arena, item.menu));
        try t.updateIcon(plat);
        t.apply(plat);
    }

    fn copyMenu(arena: Allocator, items: []const platform.MenuItem) ![]platform.MenuItem {
        const out = try arena.alloc(platform.MenuItem, items.len);
        for (items, out) |src, *dst| dst.* = switch (src) {
            .separator => .separator,
            .action => |a| blk: {
                var c = a;
                c.name = try arena.dupe(u8, a.name);
                c.key_equivalent = null;
                break :blk .{ .action = c };
            },
            .submenu => |m| .{ .submenu = .{ .name = try arena.dupe(u8, m.name), .items = try copyMenu(arena, m.items), .disabled = m.disabled } },
            .system_menu => .separator,
        };
        return out;
    }

    fn updateIcon(t: *Tray, plat: *WindowsPlatform) !void {
        const new_icon = try iconFromPng(plat.gpa, t.png, t.template, systemUsesDarkTheme());
        if (t.icon) |old| _ = w.DestroyIcon(old);
        t.icon = new_icon;
    }

    fn refreshIcon(t: *Tray, plat: *WindowsPlatform) void {
        if (!t.added or !t.template) return;
        t.updateIcon(plat) catch return;
        t.apply(plat);
    }

    fn data(t: *Tray, plat: *WindowsPlatform) w.NOTIFYICONDATAW {
        var nid: w.NOTIFYICONDATAW = .{
            .hWnd = plat.hidden,
            .uID = 1,
            .uFlags = w.NIF_MESSAGE | w.NIF_ICON | w.NIF_TIP | w.NIF_SHOWTIP,
            .uCallbackMessage = WM_APP_TRAY,
            .hIcon = t.icon,
        };
        nid.szTip = t.tooltip;
        return nid;
    }

    fn apply(t: *Tray, plat: *WindowsPlatform) void {
        var nid = t.data(plat);
        if (t.added) {
            _ = w.Shell_NotifyIconW(w.NIM_MODIFY, &nid);
            return;
        }
        if (w.Shell_NotifyIconW(w.NIM_ADD, &nid) == 0) return;
        nid.uVersion = w.NOTIFYICON_VERSION_4;
        _ = w.Shell_NotifyIconW(w.NIM_SETVERSION, &nid);
        t.added = true;
    }

    /// Explorer restarted: the icon is gone, add it again.
    fn readd(t: *Tray, plat: *WindowsPlatform) void {
        if (!t.added) return;
        t.added = false;
        t.apply(plat);
    }

    fn remove(t: *Tray, plat: *WindowsPlatform) void {
        if (t.added) {
            var nid = t.data(plat);
            _ = w.Shell_NotifyIconW(w.NIM_DELETE, &nid);
            t.added = false;
        }
        if (t.icon) |i| _ = w.DestroyIcon(i);
        t.icon = null;
        if (t.arena) |*a| a.deinit();
        t.arena = null;
        t.menu = .empty;
    }

    fn showMenu(t: *Tray, plat: *WindowsPlatform, x: i32, y: i32) void {
        if (t.menu.items.len == 0) return;
        if (plat.callbacks.will_open_menu) |f| f(plat.callbacks.ctx);
        const menu = w.CreatePopupMenu() orelse return;
        defer _ = w.DestroyMenu(menu);
        plat.menu_tags.clearRetainingCapacity();
        plat.buildMenu(menu, t.menu.items);
        const id = plat.trackMenu(menu, plat.hidden, x, y, w.TPM_BOTTOMALIGN);
        if (id == 0 or id > plat.menu_tags.items.len) return;
        const tag = plat.menu_tags.items[id - 1];
        if (plat.callbacks.menu_action) |f| f(plat.callbacks.ctx, tag);
    }
};

/// HICON from PNG bytes. `template`: a monochrome glyph tinted for the taskbar theme.
fn iconFromPng(gpa: Allocator, png: []const u8, template: bool, dark_taskbar: bool) !w.HICON {
    var decoded = try image.decode(gpa, png, .{});
    defer decoded.deinit(gpa);
    if (decoded.frames.len == 0) return error.InvalidImage;
    const f = decoded.frames[0];
    const width: i32 = @intCast(f.width);
    const height: i32 = @intCast(f.height);
    var bits: ?*anyopaque = null;
    const bmi: w.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = width, .biHeight = -height } };
    const color = w.CreateDIBSection(null, &bmi, 0, &bits, null, 0) orelse return error.IconFailed;
    defer _ = w.DeleteObject(color);
    const dst: [*]u8 = @ptrCast(bits.?);
    @memcpy(dst[0..f.pixels.len], f.pixels);
    if (template) {
        const v: u8 = if (dark_taskbar) 255 else 0;
        var i: usize = 0;
        while (i < f.pixels.len) : (i += 4) {
            dst[i] = v;
            dst[i + 1] = v;
            dst[i + 2] = v;
        }
    }
    const mask = w.CreateBitmap(width, height, 1, 1, null) orelse return error.IconFailed;
    defer _ = w.DeleteObject(mask);
    return w.CreateIconIndirect(&.{ .fIcon = w.TRUE, .hbmMask = mask, .hbmColor = color }) orelse error.IconFailed;
}

// ---------------------------------------------------------------------------------------
// comctl32 v6 without a manifest
// ---------------------------------------------------------------------------------------

/// An activation context for comctl32 v6, borrowed from shell32.dll's embedded manifest
/// (resource 124), so native controls are themed even when the executable has no
/// manifest. Activated around control creation (`withControlsContext`).
fn createControlsContext() ?w.HANDLE {
    var dir: [w.MAX_PATH]u16 = undefined;
    const n = w.GetSystemDirectoryW(&dir, dir.len);
    if (n == 0 or n + 13 >= dir.len) return null;
    var path: [w.MAX_PATH]u16 = undefined;
    @memcpy(path[0..n], dir[0..n]);
    const tail = L("\\shell32.dll");
    @memcpy(path[n..][0..tail.len], tail);
    path[n + tail.len] = 0;
    dir[n] = 0;
    const ctx: w.ACTCTXW = .{
        .dwFlags = w.ACTCTX_FLAG_RESOURCE_NAME_VALID | w.ACTCTX_FLAG_ASSEMBLY_DIRECTORY_VALID,
        .lpSource = path[0 .. n + tail.len :0].ptr,
        .lpAssemblyDirectory = dir[0..n :0].ptr,
        .lpResourceName = w.makeIntResource(124),
    };
    const h = w.CreateActCtxW(&ctx);
    if (h == w.INVALID_HANDLE_VALUE) return null;
    return h;
}

pub fn activateControlsContext(self: *WindowsPlatform) usize {
    var cookie: usize = 0;
    if (self.actctx) |h| _ = w.ActivateActCtx(h, &cookie);
    return cookie;
}

pub fn deactivateControlsContext(cookie: usize) void {
    if (cookie != 0) _ = w.DeactivateActCtx(0, cookie);
}

// ---------------------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------------------

const hidden_class = L("zpui_hidden");

/// Creates the Windows platform (gpui `current_platform`).
pub fn create(gpa: Allocator, options: Options) !platform.Platform {
    // Per-monitor v2 DPI awareness (no-op when the manifest already set it).
    _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    _ = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED | w.COINIT_DISABLE_OLE1DDE);
    const hinstance = w.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    debug_messages = w.hasEnv("ZPUI_DEBUG_MESSAGES");

    const self = try gpa.create(WindowsPlatform);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .hinstance = hinstance,
        .hidden = undefined,
        .disp = undefined,
        .text_system = undefined,
    };
    try self.disp.init(gpa, options.worker_threads);
    errdefer self.disp.deinit();
    self.text_system = try text_mod.createPlatformTextSystem(gpa);
    errdefer text_mod.destroyPlatformTextSystem(self.text_system);

    _ = w.RegisterClassExW(&.{ .lpfnWndProc = WindowsPlatform.hiddenProc, .hInstance = hinstance, .lpszClassName = hidden_class });
    self.hidden = w.CreateWindowExW(w.WS_EX_TOOLWINDOW, hidden_class, L("zpui"), w.WS_POPUP, 0, 0, 0, 0, null, null, hinstance, self) orelse return error.WindowCreationFailed;
    self.disp.wake_hwnd = self.hidden;
    hook_shared.target.store(@intFromPtr(self.hidden), .release);

    self.appearance = readAppearance();
    self.reduced_motion = readReducedMotion();
    self.actctx = createControlsContext();
    const cookie = activateControlsContext(self);
    _ = w.InitCommonControlsEx(&.{ .dwICC = w.ICC_STANDARD_CLASSES | w.ICC_BAR_CLASSES | w.ICC_UPDOWN_CLASS });
    deactivateControlsContext(cookie);
    window.registerClass(hinstance);
    return self.platformInterface();
}
