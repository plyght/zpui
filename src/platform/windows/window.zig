//! A Win32 window (`platform.Window`): input translation, per-monitor-v2 DPI,
//! DirectComposition presentation through the D3D11 renderer, overlay windows
//! (docs/DESKTOP_OVERLAY.md), native child controls and native context menus.
//!
//! Overlays (`WindowKind.overlay`): `WS_POPUP` with `WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
//! WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_NOREDIRECTIONBITMAP`, `MA_NOACTIVATE`, no
//! taskbar / Alt-Tab entry, per-pixel alpha through a premultiplied composition
//! swapchain. Pointer pass-through uses `WS_EX_TRANSPARENT` (with `WS_EX_LAYERED`, the
//! only way to let clicks reach windows of *other* processes; `HTTRANSPARENT` only
//! forwards to windows of the same thread). An input region (`setInputRegion`) is
//! enforced by toggling `WS_EX_TRANSPARENT` from the pointer position, which a
//! low-level mouse hook on the platform's hook thread reports even while the window is
//! click-through (`WM_NCHITTEST` still answers `HTTRANSPARENT` outside the rects for the
//! moment before the style flips).
//!
//! Resizing an anchored overlay (`resize`) keeps the anchor corner fixed: the new rect
//! is computed from the anchor, the core is told the new size and a frame is drawn
//! right away (not at the next vblank); `draw` resizes the swapchain synchronously
//! (`ResizeBuffers`), presents, and only then moves the window with one `SetWindowPos`
//! (`SWP_NOACTIVATE | SWP_NOZORDER`), so pixels and window geometry change together.
//! DirectComposition never stretches a swapchain to the window, so no frame shows
//! scaled stale content.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const input = @import("../../input.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const color = @import("../../color.zig");
const w = @import("win32.zig");
const keyboard = @import("keyboard.zig");
const native_controls = @import("native_controls.zig");
const plat_mod = @import("windows.zig");
const Renderer = @import("../../renderer/d3d11/Renderer.zig");

const WindowsPlatform = plat_mod.WindowsPlatform;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.windows);
const Point = platform.Point;
const Size = platform.Size;
const Bounds = platform.Bounds;

pub const class_name = L("zpui_window");

pub fn registerClass(hinstance: w.HINSTANCE) void {
    _ = w.RegisterClassExW(&.{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hIcon = w.LoadIconW(hinstance, 1) orelse w.LoadIconW(null, w.IDI_APPLICATION),
        .lpszClassName = class_name,
    });
}

/// zpui's double-click rules on Windows: the system interval and a 4px box.
const ClickState = struct {
    button: ?input.MouseButton = null,
    time_ms: u32 = 0,
    position: Point = .zero,
    count: u32 = 0,

    fn press(s: *ClickState, button: input.MouseButton, position: Point, time_ms: u32) u32 {
        const near = @abs(position.x - s.position.x) <= 4 and @abs(position.y - s.position.y) <= 4;
        const fast = time_ms -% s.time_ms <= w.GetDoubleClickTime();
        s.count = if (s.button == button and near and fast) s.count + 1 else 1;
        s.button = button;
        s.time_ms = time_ms;
        s.position = position;
        return s.count;
    }
};

const RegionMode = enum { all, none, rects };

pub const Window = struct {
    plat: *WindowsPlatform,
    gpa: Allocator,
    hwnd: w.HWND = undefined,
    kind: platform.WindowKind,
    background: platform.WindowBackgroundAppearance,
    callbacks: platform.WindowCallbacks = .{},
    input_handler: ?platform.InputHandler = null,

    /// Logical content size and the window's DPI scale.
    size: Size = .zero,
    scale: f32 = 1,
    dpi: u32 = 96,
    origin: Point = .zero,
    min_size: ?Size = null,

    active: bool = false,
    hovered: bool = false,
    tracking_leave: bool = false,
    mouse_position: Point = .zero,
    modifiers: input.Modifiers = .{},
    capslock: bool = false,
    pressed: ?input.MouseButton = null,
    click: ClickState = .{},
    suppress_char: bool = false,
    high_surrogate: u16 = 0,
    ime_area: ?Bounds = null,

    renderer: ?Renderer = null,
    frame_requested: bool = false,
    in_draw: bool = false,
    /// A frame has been presented since the swapchain was (re)created.
    presented: bool = false,
    visible: bool = false,
    minimized: bool = false,
    closed: bool = false,
    maximized: bool = false,
    fullscreen_restore: ?struct { rect: w.RECT, style: w.LONG_PTR } = null,

    // Overlay state.
    anchor: ?platform.OverlayAnchor = null,
    anchor_display: ?u32 = null,
    passthrough: bool = false,
    region: RegionMode = .all,
    region_rects: std.ArrayList(Bounds) = .empty,
    ex_transparent: bool = false,
    /// Rect to apply right after the next present (anchored resize), physical px.
    pending_rect: ?w.RECT = null,

    natives: native_controls.Host = .{},
    // drawLayered scratch scenes (reused).
    base_scene: scene_mod.Scene = .{},
    overlay_scene: scene_mod.Scene = .{},

    pub fn platformWindow(self: *Window) platform.Window {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn fromWindow(pw: platform.Window) *Window {
        return @ptrCast(@alignCast(pw.ptr));
    }

    fn isOverlay(self: *const Window) bool {
        return self.kind == .overlay;
    }

    // -----------------------------------------------------------------------------------
    // Creation
    // -----------------------------------------------------------------------------------

    fn styles(params: platform.WindowParams) struct { style: w.DWORD, ex: w.DWORD } {
        var style: w.DWORD = w.WS_CLIPCHILDREN;
        var ex: w.DWORD = 0;
        switch (params.kind) {
            .overlay => {
                style |= w.WS_POPUP;
                ex |= w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE | w.WS_EX_LAYERED | w.WS_EX_NOREDIRECTIONBITMAP;
                if (params.mouse_passthrough) ex |= w.WS_EX_TRANSPARENT;
            },
            .popup => {
                style |= w.WS_POPUP;
                ex |= w.WS_EX_TOOLWINDOW | w.WS_EX_NOREDIRECTIONBITMAP;
                if (!params.focus) ex |= w.WS_EX_NOACTIVATE;
            },
            .normal, .floating => {
                style |= if (params.titlebar != null and params.decorations == .server) w.WS_OVERLAPPEDWINDOW else (w.WS_POPUP | w.WS_THICKFRAME | w.WS_MINIMIZEBOX | w.WS_MAXIMIZEBOX | w.WS_SYSMENU);
                if (params.kind == .floating) ex |= w.WS_EX_TOPMOST;
                // Fully transparent windows need no redirection surface; opaque and
                // blurred (Mica) windows keep it for their native child controls.
                if (params.background == .transparent) ex |= w.WS_EX_NOREDIRECTIONBITMAP;
            },
        }
        return .{ .style = style, .ex = ex };
    }

    pub fn create(plat: *WindowsPlatform, params: platform.WindowParams) !*Window {
        const gpa = plat.gpa;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .plat = plat,
            .gpa = gpa,
            .kind = params.kind,
            .background = params.background,
            .min_size = params.min_size,
            .anchor = params.anchor,
            .anchor_display = params.display_id,
            .passthrough = params.mouse_passthrough,
            .ex_transparent = params.mouse_passthrough and params.kind == .overlay,
        };
        const st = styles(params);
        const mon = (if (params.display_id) |id| plat_mod.monitorById(id) else null) orelse plat_mod.primaryMonitor() orelse return error.NoMonitor;
        self.dpi = plat_mod.monitorDpi(mon);
        self.scale = @as(f32, @floatFromInt(self.dpi)) / 96.0;
        self.size = .{ .width = @max(params.bounds.size.width, 1), .height = @max(params.bounds.size.height, 1) };
        const rect = self.initialRect(mon, params, st.style, st.ex);

        var title_buf: [256]u16 = undefined;
        const title = w.wideBuf(&title_buf, if (params.titlebar) |t| t.title else "");
        const hwnd = w.CreateWindowExW(st.ex, class_name, title.ptr, st.style, rect.left, rect.top, rect.width(), rect.height(), null, null, plat.hinstance, self) orelse
            return error.WindowCreationFailed;
        self.hwnd = hwnd;
        errdefer {
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
            _ = w.DestroyWindow(hwnd);
        }

        // The monitor's DPI may differ from what the rect assumed (window placed on another
        // monitor): re-derive and fix the size.
        const real_dpi = w.GetDpiForWindow(hwnd);
        if (real_dpi != 0 and real_dpi != self.dpi) {
            self.dpi = real_dpi;
            self.scale = @as(f32, @floatFromInt(real_dpi)) / 96.0;
            const r2 = if (self.anchor != null) self.anchoredRect() else self.outerRectAt(rect.left, rect.top);
            _ = w.SetWindowPos(hwnd, null, r2.left, r2.top, r2.width(), r2.height(), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        }
        self.syncClientSize();

        if (st.ex & w.WS_EX_LAYERED != 0) _ = w.SetLayeredWindowAttributes(hwnd, 0, 255, w.LWA_ALPHA);
        self.applyDwmAttributes();

        const dev = self.deviceSize();
        self.renderer = Renderer.init(gpa, .{
            .size = .{ .width = @intCast(dev.width), .height = @intCast(dev.height) },
            .surface = .{ .hwnd = @ptrCast(hwnd) },
            .transparent = params.background != .opaque_ or self.isOverlay(),
        }) catch |e| blk: {
            log.err("renderer init failed: {t}; window will not draw", .{e});
            break :blk null;
        };
        try plat.windows.append(gpa, self);

        if (params.show) {
            if (self.isOverlay()) {
                _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
                _ = w.SetWindowPos(hwnd, w.hwndFromInt(w.HWND_TOPMOST), 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
            } else _ = w.ShowWindow(hwnd, if (params.focus) w.SW_SHOW else w.SW_SHOWNOACTIVATE);
            self.visible = true;
        }
        plat.updateHooks();
        self.requestFrameImpl();
        return self;
    }

    fn initialRect(self: *Window, mon: w.HMONITOR, params: platform.WindowParams, style: w.DWORD, ex: w.DWORD) w.RECT {
        if (self.isOverlay() and self.anchor != null) return self.anchoredRectOn(mon);
        var info: w.MONITORINFOEXW = .{};
        _ = w.GetMonitorInfoW(mon, &info);
        const x = info.rcMonitor.left + @as(i32, @intFromFloat(@round(params.bounds.origin.x * self.scale)));
        const y = info.rcMonitor.top + @as(i32, @intFromFloat(@round(params.bounds.origin.y * self.scale)));
        _ = style;
        _ = ex;
        return self.outerRectAt(x, y);
    }

    /// Outer rect for the current logical content size at physical `x`,`y`.
    fn outerRectAt(self: *Window, x: i32, y: i32) w.RECT {
        const dev = self.deviceSize();
        var r: w.RECT = .{ .left = x, .top = y, .right = x + dev.width, .bottom = y + dev.height };
        if (self.hasFrame()) {
            const style: w.DWORD = @truncate(@as(usize, @bitCast(if (self.hwndValid()) w.GetWindowLongPtrW(self.hwnd, w.GWL_STYLE) else @as(isize, w.WS_OVERLAPPEDWINDOW))));
            const ex: w.DWORD = @truncate(@as(usize, @bitCast(if (self.hwndValid()) w.GetWindowLongPtrW(self.hwnd, w.GWL_EXSTYLE) else @as(isize, 0))));
            _ = w.AdjustWindowRectExForDpi(&r, style, w.FALSE, ex, self.dpi);
            // Keep the requested origin for the client area's top-left corner.
            const dx = x - r.left;
            r.left += dx;
            r.right += dx;
        }
        return r;
    }

    fn hwndValid(self: *const Window) bool {
        return @intFromPtr(self.hwnd) != 0 and w.IsWindow(self.hwnd) != 0;
    }

    fn hasFrame(self: *const Window) bool {
        return self.kind == .normal or self.kind == .floating;
    }

    pub fn deviceSize(self: *const Window) struct { width: i32, height: i32 } {
        return .{
            .width = @intFromFloat(@max(1, @round(self.size.width * self.scale))),
            .height = @intFromFloat(@max(1, @round(self.size.height * self.scale))),
        };
    }

    // -- anchoring -------------------------------------------------------------------------

    fn anchorMonitor(self: *Window) ?w.HMONITOR {
        if (self.anchor_display) |id| if (plat_mod.monitorById(id)) |m| return m;
        if (self.hwndValid()) return w.MonitorFromWindow(self.hwnd, w.MONITOR_DEFAULTTOPRIMARY);
        return plat_mod.primaryMonitor();
    }

    fn anchoredRect(self: *Window) w.RECT {
        const mon = self.anchorMonitor() orelse return .{};
        return self.anchoredRectOn(mon);
    }

    /// The window rect pinned to `anchor`'s corner of `mon`'s work area (physical px).
    fn anchoredRectOn(self: *Window, mon: w.HMONITOR) w.RECT {
        const a = self.anchor orelse return .{};
        var info: w.MONITORINFOEXW = .{};
        _ = w.GetMonitorInfoW(mon, &info);
        const work = info.rcWork;
        const dev = self.deviceSize();
        // Physical pixels throughout: the margin scales with the monitor's DPI.
        const o = platform.desktop.anchoredOrigin(
            .{ .corner = a.corner, .margin = .{ .x = @round(a.margin.x * self.scale), .y = @round(a.margin.y * self.scale) } },
            .{ .origin = .{ .x = @floatFromInt(work.left), .y = @floatFromInt(work.top) }, .size = .{ .width = @floatFromInt(work.width()), .height = @floatFromInt(work.height()) } },
            .{ .width = @floatFromInt(dev.width), .height = @floatFromInt(dev.height) },
        );
        const left: i32 = @intFromFloat(o.x);
        const top: i32 = @intFromFloat(o.y);
        return .{ .left = left, .top = top, .right = left + dev.width, .bottom = top + dev.height };
    }

    fn applyDwmAttributes(self: *Window) void {
        const dark: w.BOOL = @intFromBool(self.plat.appearance == .dark or self.plat.appearance == .vibrant_dark);
        _ = w.DwmSetWindowAttribute(self.hwnd, w.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(w.BOOL));
        if (self.isOverlay()) {
            // No show/hide animation, no rounded corners clipping the pet.
            const on: w.BOOL = w.TRUE;
            _ = w.DwmSetWindowAttribute(self.hwnd, 3, &on, @sizeOf(w.BOOL)); // DWMWA_TRANSITIONS_FORCEDISABLED
            const no_round: u32 = 1; // DWMWCP_DONOTROUND
            _ = w.DwmSetWindowAttribute(self.hwnd, w.DWMWA_WINDOW_CORNER_PREFERENCE, &no_round, @sizeOf(u32));
        } else if (self.background == .blurred) {
            // Windows 11 Mica behind the whole client area (ignored on Windows 10).
            const margins: w.MARGINS = .{ .left = -1, .right = -1, .top = -1, .bottom = -1 };
            _ = w.DwmExtendFrameIntoClientArea(self.hwnd, &margins);
            const mica: u32 = w.DWMSBT_MAINWINDOW;
            _ = w.DwmSetWindowAttribute(self.hwnd, w.DWMWA_SYSTEMBACKDROP_TYPE, &mica, @sizeOf(u32));
        }
    }

    // -----------------------------------------------------------------------------------
    // Size / frames
    // -----------------------------------------------------------------------------------

    /// Read the client size from the HWND; true (and the core notified) when it changed.
    fn syncClientSize(self: *Window) void {
        var r: w.RECT = .{};
        _ = w.GetClientRect(self.hwnd, &r);
        if (r.width() <= 0 or r.height() <= 0) return;
        _ = self.setSizeAndScale(.{
            .width = @as(f32, @floatFromInt(r.width())) / self.scale,
            .height = @as(f32, @floatFromInt(r.height())) / self.scale,
        }, self.scale);
        var wr: w.RECT = .{};
        _ = w.GetWindowRect(self.hwnd, &wr);
        self.origin = .{ .x = @as(f32, @floatFromInt(wr.left)) / self.scale, .y = @as(f32, @floatFromInt(wr.top)) / self.scale };
    }

    fn setSizeAndScale(self: *Window, size: Size, scale: f32) bool {
        const dev_before = self.deviceSize();
        const scale_changed = scale != self.scale;
        self.size = size;
        self.scale = scale;
        const dev_after = self.deviceSize();
        if (!scale_changed and dev_before.width == dev_after.width and dev_before.height == dev_after.height) return false;
        if (self.callbacks.resize) |f| f(self.callbacks.ctx, size, scale);
        return true;
    }

    pub fn fireRequestFrame(self: *Window, force: bool) void {
        if (self.closed) return;
        if (self.callbacks.request_frame) |f| f(self.callbacks.ctx, force);
    }

    fn requestFrameImpl(self: *Window) void {
        if (self.closed or !self.visible) return;
        if (self.frame_requested) return;
        self.frame_requested = true;
        self.plat.wantFrame();
    }

    /// Draw now instead of at the next vblank (resizes).
    fn frameNow(self: *Window) void {
        _ = w.PostMessageW(self.hwnd, plat_mod.WM_APP_FRAME_NOW, 0, 0);
    }

    fn drawScene(self: *Window, scene: *const scene_mod.Scene) !void {
        const r = if (self.renderer) |*r| r else return error.NoRenderer;
        if (!self.visible or self.minimized) return;
        self.in_draw = true;
        defer self.in_draw = false;
        const dev = self.deviceSize();
        const clear = if (self.background == .opaque_ and !self.isOverlay()) self.opaqueClear() else color.transparent_black;
        try r.drawScene(scene, .{ .width = dev.width, .height = dev.height }, self.scale, clear);
        self.presented = true;
        // Native child controls paint on WM_PAINT, which the queue only yields once no
        // posted message is pending. While zpui animates and a frame takes longer than a
        // vblank (software adapters, loaded GPUs) the next WM_APP_VSYNC is always queued
        // already, so flush the children's pending paints here (validates only what is
        // invalid; a no-op when nothing changed).
        if (self.natives.entries.items.len != 0) _ = w.RedrawWindow(self.hwnd, null, null, w.RDW_UPDATENOW | w.RDW_ALLCHILDREN);
        self.applyPendingRect();
    }

    fn opaqueClear(self: *Window) color.Hsla {
        const dark = self.plat.appearance == .dark or self.plat.appearance == .vibrant_dark;
        return if (dark) color.hsla(0, 0, 0.12, 1) else color.hsla(0, 0, 0.98, 1);
    }

    /// The anchored-resize rect, applied right after the frame of the new size presented.
    fn applyPendingRect(self: *Window) void {
        const r = self.pending_rect orelse return;
        self.pending_rect = null;
        _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOACTIVATE | w.SWP_NOZORDER | w.SWP_NOCOPYBITS | w.SWP_NOREDRAW);
        self.origin = .{ .x = @as(f32, @floatFromInt(r.left)) / self.scale, .y = @as(f32, @floatFromInt(r.top)) / self.scale };
    }

    // -----------------------------------------------------------------------------------
    // Overlay input region / pass-through
    // -----------------------------------------------------------------------------------

    pub fn needsPointerTracking(self: *const Window) bool {
        return self.isOverlay() and !self.closed and self.visible and !self.passthrough and self.region == .rects;
    }

    fn setExTransparent(self: *Window, on: bool) void {
        if (self.ex_transparent == on) return;
        self.ex_transparent = on;
        const ex = w.GetWindowLongPtrW(self.hwnd, w.GWL_EXSTYLE);
        const bit: isize = w.WS_EX_TRANSPARENT;
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_EXSTYLE, if (on) ex | bit else ex & ~bit);
    }

    /// Whether physical screen point `pt` falls inside an input rect.
    fn pointInRegion(self: *Window, pt: w.POINT) bool {
        switch (self.region) {
            .all => return true,
            .none => return false,
            .rects => {},
        }
        var wr: w.RECT = .{};
        if (w.GetWindowRect(self.hwnd, &wr) == 0 or w.PtInRect(&wr, pt) == 0) return false;
        const p: Point = .{
            .x = @as(f32, @floatFromInt(pt.x - wr.left)) / self.scale,
            .y = @as(f32, @floatFromInt(pt.y - wr.top)) / self.scale,
        };
        for (self.region_rects.items) |b| if (b.contains(p)) return true;
        return false;
    }

    /// The pointer moved (hook thread report): click-through unless it is over a rect.
    pub fn updatePointerTransparency(self: *Window, pt: w.POINT) void {
        if (!self.isOverlay() or self.closed) return;
        if (self.passthrough) return self.setExTransparent(true);
        // While dragging (captured) the window keeps the pointer.
        if (self.pressed != null) return self.setExTransparent(false);
        self.setExTransparent(!self.pointInRegion(pt));
    }

    fn refreshTransparency(self: *Window) void {
        if (!self.isOverlay()) {
            // Non-overlay windows: pass-through needs layering; best effort via the style.
            return;
        }
        var pt: w.POINT = .{};
        _ = w.GetCursorPos(&pt);
        self.updatePointerTransparency(pt);
        self.plat.updateHooks();
    }

    fn hitTest(self: *Window, lparam: w.LPARAM) ?w.LRESULT {
        if (!self.isOverlay()) return null;
        if (self.passthrough) return w.HTTRANSPARENT;
        if (self.pressed != null) return w.HTCLIENT;
        const pt: w.POINT = .{ .x = w.xParam(lparam), .y = w.yParam(lparam) };
        return if (self.pointInRegion(pt)) w.HTCLIENT else w.HTTRANSPARENT;
    }

    // -----------------------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------------------

    fn dispatchInput(self: *Window, event: input.PlatformInput) platform.DispatchEventResult {
        const f = self.callbacks.input orelse return .{};
        return f(self.callbacks.ctx, event);
    }

    fn logicalPoint(self: *const Window, lparam: w.LPARAM) Point {
        return .{
            .x = @as(f32, @floatFromInt(w.xParam(lparam))) / self.scale,
            .y = @as(f32, @floatFromInt(w.yParam(lparam))) / self.scale,
        };
    }

    fn syncModifiers(self: *Window) void {
        const m = keyboard.currentModifiers();
        const caps = keyboard.capsLock();
        if (@as(u8, @bitCast(m)) == @as(u8, @bitCast(self.modifiers)) and caps == self.capslock) return;
        self.modifiers = m;
        self.capslock = caps;
        _ = self.dispatchInput(.{ .modifiers_changed = .{ .modifiers = m, .capslock = caps } });
    }

    fn onMouseMove(self: *Window, lparam: w.LPARAM) void {
        const pos = self.logicalPoint(lparam);
        if (!self.tracking_leave) {
            var tme: w.TRACKMOUSEEVENT = .{ .dwFlags = w.TME_LEAVE, .hwndTrack = self.hwnd };
            _ = w.TrackMouseEvent(&tme);
            self.tracking_leave = true;
        }
        if (!self.hovered) {
            self.hovered = true;
            if (self.callbacks.hover_status_change) |f| f(self.callbacks.ctx, true);
        }
        if (pos.x == self.mouse_position.x and pos.y == self.mouse_position.y) return;
        self.mouse_position = pos;
        self.modifiers = keyboard.currentModifiers();
        _ = self.dispatchInput(.{ .mouse_move = .{ .position = pos, .pressed_button = self.pressed, .modifiers = self.modifiers } });
    }

    fn onMouseLeave(self: *Window) void {
        self.tracking_leave = false;
        if (self.pressed != null) return; // captured drag continues outside
        self.hovered = false;
        if (self.callbacks.hover_status_change) |f| f(self.callbacks.ctx, false);
        _ = self.dispatchInput(.{ .mouse_exited = .{ .position = self.mouse_position, .modifiers = self.modifiers } });
    }

    fn onButton(self: *Window, button: input.MouseButton, down: bool, lparam: w.LPARAM) void {
        const pos = self.logicalPoint(lparam);
        self.mouse_position = pos;
        self.modifiers = keyboard.currentModifiers();
        if (down) {
            const count = self.click.press(button, pos, @bitCast(w.GetMessageTime()));
            if (self.pressed == null) _ = w.SetCapture(self.hwnd);
            self.pressed = button;
            if (self.isOverlay()) self.setExTransparent(false);
            _ = self.dispatchInput(.{ .mouse_down = .{ .button = button, .position = pos, .modifiers = self.modifiers, .click_count = count, .first_mouse = !self.active and !self.isOverlay() } });
        } else {
            const was = self.pressed;
            self.pressed = null;
            if (was != null and w.GetCapture() == self.hwnd) _ = w.ReleaseCapture();
            _ = self.dispatchInput(.{ .mouse_up = .{ .button = button, .position = pos, .modifiers = self.modifiers, .click_count = self.click.count } });
            if (self.isOverlay()) self.refreshTransparency();
        }
    }

    fn onCaptureLost(self: *Window) void {
        const b = self.pressed orelse return;
        self.pressed = null;
        _ = self.dispatchInput(.{ .mouse_up = .{ .button = b, .position = self.mouse_position, .modifiers = self.modifiers, .click_count = self.click.count } });
        if (self.isOverlay()) self.refreshTransparency();
    }

    fn onWheel(self: *Window, wparam: w.WPARAM, lparam: w.LPARAM, horizontal: bool) void {
        var pt: w.POINT = .{ .x = w.xParam(lparam), .y = w.yParam(lparam) };
        _ = w.ScreenToClient(self.hwnd, &pt);
        const pos: Point = .{ .x = @as(f32, @floatFromInt(pt.x)) / self.scale, .y = @as(f32, @floatFromInt(pt.y)) / self.scale };
        const delta: f32 = @floatFromInt(@as(i16, @bitCast(w.hiword(@as(isize, @bitCast(wparam))))));
        var lines: w.UINT = 3;
        _ = w.SystemParametersInfoW(if (horizontal) w.SPI_GETWHEELSCROLLCHARS else w.SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
        if (lines == 0xFFFFFFFF) lines = 3; // "one screen at a time"
        const amount = delta / @as(f32, @floatFromInt(w.WHEEL_DELTA)) * @as(f32, @floatFromInt(lines));
        self.modifiers = keyboard.currentModifiers();
        var d: Point = if (horizontal) .{ .x = -amount, .y = 0 } else .{ .x = 0, .y = amount };
        if (!horizontal and self.modifiers.shift) d = .{ .x = d.y, .y = 0 };
        _ = self.dispatchInput(.{ .scroll_wheel = .{ .position = pos, .delta = .{ .lines = d }, .modifiers = self.modifiers } });
    }

    /// WM_KEYDOWN / WM_SYSKEYDOWN; returns whether the event was handled.
    fn onKey(self: *Window, down: bool, wparam: w.WPARAM, lparam: w.LPARAM) bool {
        const vk: u32 = @truncate(wparam);
        const lp: usize = @bitCast(lparam);
        const scan: u32 = @truncate((lp >> 16) & 0xff);
        const extended = (lp >> 24) & 1 != 0;
        if (keyboard.isModifierKey(vk)) {
            self.syncModifiers();
            return false;
        }
        self.syncModifiers();
        var name_buf: [8]u8 = undefined;
        var char_buf: [8]u8 = undefined;
        const key = keyboard.keyName(vk, extended) orelse keyboard.charKeyName(vk, scan, &name_buf) orelse return false;
        const key_char = if (down) keyboard.typedChar(vk, scan, &char_buf) else null;
        const ks: input.Keystroke = .{ .modifiers = self.modifiers, .key = key, .key_char = key_char };
        if (down) {
            const held = (lp >> 30) & 1 != 0;
            const r = self.dispatchInput(.{ .key_down = .{ .keystroke = ks, .is_held = held } });
            const handled = !r.propagate or r.default_prevented;
            // The WM_CHAR that TranslateMessage queued for this key must not type too.
            self.suppress_char = handled;
            return handled;
        }
        const r = self.dispatchInput(.{ .key_up = .{ .keystroke = ks } });
        return !r.propagate;
    }

    fn onChar(self: *Window, wparam: w.WPARAM) void {
        const unit: u16 = @truncate(wparam);
        if (self.suppress_char) {
            if (unit >= 0xD800 and unit < 0xDC00) return; // the low half follows; drop both
            self.suppress_char = false;
            return;
        }
        if (unit >= 0xD800 and unit < 0xDC00) {
            self.high_surrogate = unit;
            return;
        }
        var units: [2]u16 = .{ unit, 0 };
        var n: usize = 1;
        if (unit >= 0xDC00 and unit < 0xE000 and self.high_surrogate != 0) {
            units = .{ self.high_surrogate, unit };
            n = 2;
        }
        self.high_surrogate = 0;
        if (units[0] < 0x20 or units[0] == 0x7f) return; // control characters are keys
        const m = keyboard.currentModifiers();
        if (m.control or m.alt) return;
        const h = self.input_handler orelse return;
        var buf: [8]u8 = undefined;
        const s = w.wideToUtf8Buf(&buf, units[0..n]);
        if (s.len > 0) h.vtable.replaceTextInRange(h.ptr, null, s);
    }

    fn onImeComposition(self: *Window, lparam: w.LPARAM) bool {
        const h = self.input_handler orelse return false;
        const himc = w.ImmGetContext(self.hwnd) orelse return false;
        defer _ = w.ImmReleaseContext(self.hwnd, himc);
        var buf: [512]u16 = undefined;
        var out: [1536]u8 = undefined;
        if (lparam & w.GCS_RESULTSTR != 0) {
            const bytes = w.ImmGetCompositionStringW(himc, @intCast(w.GCS_RESULTSTR), &buf, @sizeOf(@TypeOf(buf)));
            if (bytes > 0) {
                const s = w.wideToUtf8Buf(&out, buf[0..@intCast(@divTrunc(bytes, 2))]);
                h.vtable.replaceTextInRange(h.ptr, h.vtable.markedTextRange(h.ptr), s);
                h.vtable.unmarkText(h.ptr);
            }
        }
        if (lparam & w.GCS_COMPSTR != 0) {
            const bytes = w.ImmGetCompositionStringW(himc, @intCast(w.GCS_COMPSTR), &buf, @sizeOf(@TypeOf(buf)));
            const s = if (bytes > 0) w.wideToUtf8Buf(&out, buf[0..@intCast(@divTrunc(bytes, 2))]) else out[0..0];
            if (s.len == 0) {
                if (h.vtable.markedTextRange(h.ptr)) |r| h.vtable.replaceTextInRange(h.ptr, r, "");
            } else h.vtable.replaceAndMarkTextInRange(h.ptr, null, s, null);
        }
        self.positionIme();
        return true;
    }

    fn positionIme(self: *Window) void {
        const area = self.ime_area orelse blk: {
            const h = self.input_handler orelse return;
            const sel = h.vtable.selectedTextRange(h.ptr) orelse return;
            break :blk h.vtable.boundsForRange(h.ptr, sel.range) orelse return;
        };
        const himc = w.ImmGetContext(self.hwnd) orelse return;
        defer _ = w.ImmReleaseContext(self.hwnd, himc);
        const x: i32 = @intFromFloat(@round(area.origin.x * self.scale));
        const y: i32 = @intFromFloat(@round(area.origin.y * self.scale));
        const b: i32 = @intFromFloat(@round((area.origin.y + area.size.height) * self.scale));
        _ = w.ImmSetCompositionWindow(himc, &.{ .dwStyle = w.CFS_POINT, .ptCurrentPos = .{ .x = x, .y = y }, .rcArea = .{} });
        _ = w.ImmSetCandidateWindow(himc, &.{ .dwIndex = 0, .dwStyle = w.CFS_EXCLUDE, .ptCurrentPos = .{ .x = x, .y = b }, .rcArea = .{ .left = x, .top = y, .right = x + 1, .bottom = b } });
    }

    fn onDpiChanged(self: *Window, wparam: w.WPARAM, lparam: w.LPARAM) void {
        const dpi: u32 = w.loword(@as(isize, @bitCast(wparam)));
        if (dpi == 0) return;
        self.dpi = dpi;
        const new_scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        const old_scale = self.scale;
        self.scale = new_scale;
        if (self.isOverlay()) {
            // Keep the logical size; re-pin to the corner of the (new) monitor.
            const r = if (self.anchor != null) self.anchoredRect() else blk: {
                var wr: w.RECT = .{};
                _ = w.GetWindowRect(self.hwnd, &wr);
                const dev = self.deviceSize();
                break :blk w.RECT{ .left = wr.left, .top = wr.top, .right = wr.left + dev.width, .bottom = wr.top + dev.height };
            };
            self.pending_rect = null;
            _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        } else {
            const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        }
        self.scale = old_scale; // let setSizeAndScale see the change
        var cr: w.RECT = .{};
        _ = w.GetClientRect(self.hwnd, &cr);
        const size: Size = if (self.isOverlay()) self.size else .{
            .width = @as(f32, @floatFromInt(cr.width())) / new_scale,
            .height = @as(f32, @floatFromInt(cr.height())) / new_scale,
        };
        _ = self.setSizeAndScale(size, new_scale);
        self.natives.onDpiChanged(self);
        self.frameNow();
    }

    pub fn onDisplayChange(self: *Window) void {
        if (self.isOverlay() and self.anchor != null and self.visible) {
            const r = self.anchoredRect();
            _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        }
    }

    pub fn onAppearanceChanged(self: *Window) void {
        self.applyDwmAttributes();
        self.natives.onAppearance(self);
        if (self.callbacks.appearance_changed) |f| f(self.callbacks.ctx);
        self.requestFrameImpl();
    }

    pub fn isDark(self: *const Window) bool {
        return self.plat.appearance == .dark or self.plat.appearance == .vibrant_dark;
    }

    fn handleMessage(self: *Window, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) ?w.LRESULT {
        switch (msg) {
            w.WM_CLOSE => {
                const allow = if (self.callbacks.should_close) |f| f(self.callbacks.ctx) else true;
                if (allow) self.destroyNow();
                return 0;
            },
            w.WM_NCDESTROY => {
                // Destroyed by someone else (parent / system): tear down our side.
                if (!self.closed) self.destroyAfterHwnd();
                return null;
            },
            w.WM_ERASEBKGND => return 1,
            w.WM_PAINT => {
                _ = w.ValidateRect(self.hwnd, null);
                // Composition keeps presented content: only a window that has nothing on
                // screen yet (new, restored, re-shown) needs a frame. Never draw from here
                // (a present that invalidates would loop).
                if (!self.presented and self.visible) self.requestFrameImpl();
                return 0;
            },
            w.WM_SIZE => {
                self.minimized = wparam == w.SIZE_MINIMIZED;
                self.maximized = wparam == w.SIZE_MAXIMIZED;
                if (self.minimized) {
                    if (self.renderer) |*r| r.suspendTargets();
                    self.presented = false;
                    return 0;
                }
                if (!self.presented) self.requestFrameImpl();
                if (self.isOverlay() or self.in_draw) return 0; // overlays size through `resize`
                const width: f32 = @floatFromInt(w.loword(lparam));
                const height: f32 = @floatFromInt(w.hiword(lparam));
                if (width <= 0 or height <= 0) return 0;
                if (self.setSizeAndScale(.{ .width = width / self.scale, .height = height / self.scale }, self.scale)) {
                    // Live resize: draw synchronously so the new size is never stale.
                    self.fireRequestFrame(true);
                }
                return 0;
            },
            w.WM_MOVE => {
                var wr: w.RECT = .{};
                _ = w.GetWindowRect(self.hwnd, &wr);
                self.origin = .{ .x = @as(f32, @floatFromInt(wr.left)) / self.scale, .y = @as(f32, @floatFromInt(wr.top)) / self.scale };
                if (self.callbacks.moved) |f| f(self.callbacks.ctx);
                return 0;
            },
            w.WM_GETMINMAXINFO => {
                if (self.min_size) |m| {
                    const info: *w.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    var r: w.RECT = .{ .right = @intFromFloat(@round(m.width * self.scale)), .bottom = @intFromFloat(@round(m.height * self.scale)) };
                    const style: w.DWORD = @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(self.hwnd, w.GWL_STYLE))));
                    _ = w.AdjustWindowRectExForDpi(&r, style, w.FALSE, 0, self.dpi);
                    info.ptMinTrackSize = .{ .x = r.width(), .y = r.height() };
                }
                return 0;
            },
            w.WM_DPICHANGED => {
                self.onDpiChanged(wparam, lparam);
                return 0;
            },
            w.WM_ENTERSIZEMOVE => self.plat.disp.enterModal(),
            w.WM_EXITSIZEMOVE => self.plat.disp.exitModal(),
            w.WM_ACTIVATE => {
                const active = w.loword(@as(isize, @bitCast(wparam))) != 0;
                if (active != self.active) {
                    self.active = active;
                    if (self.callbacks.active_status_change) |f| f(self.callbacks.ctx, active);
                }
                if (active) self.syncModifiers();
                return null;
            },
            w.WM_MOUSEACTIVATE => if (self.isOverlay() or self.kind == .popup) return w.MA_NOACTIVATE,
            w.WM_NCHITTEST => if (self.hitTest(lparam)) |r| return r,
            w.WM_SETCURSOR => if (w.loword(lparam) == @as(u16, @intCast(w.HTCLIENT))) {
                _ = w.SetCursor(self.plat.cursorHandle());
                return 1;
            },
            w.WM_MOUSEMOVE => {
                self.onMouseMove(lparam);
                return 0;
            },
            w.WM_MOUSELEAVE => {
                self.onMouseLeave();
                return 0;
            },
            w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_RBUTTONDOWN, w.WM_RBUTTONUP, w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_XBUTTONDOWN, w.WM_XBUTTONUP, w.WM_LBUTTONDBLCLK => {
                const button: input.MouseButton = switch (msg) {
                    w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_LBUTTONDBLCLK => .left,
                    w.WM_RBUTTONDOWN, w.WM_RBUTTONUP => .right,
                    w.WM_MBUTTONDOWN, w.WM_MBUTTONUP => .middle,
                    else => if (w.hiword(@as(isize, @bitCast(wparam))) == w.XBUTTON1) .back else .forward,
                };
                const down = msg == w.WM_LBUTTONDOWN or msg == w.WM_RBUTTONDOWN or msg == w.WM_MBUTTONDOWN or msg == w.WM_XBUTTONDOWN or msg == w.WM_LBUTTONDBLCLK;
                self.onButton(button, down, lparam);
                return if (msg == w.WM_XBUTTONDOWN or msg == w.WM_XBUTTONUP) 1 else 0;
            },
            w.WM_CAPTURECHANGED => {
                if (@as(usize, @bitCast(lparam)) != @intFromPtr(self.hwnd)) self.onCaptureLost();
                return 0;
            },
            w.WM_MOUSEWHEEL, w.WM_MOUSEHWHEEL => {
                self.onWheel(wparam, lparam, msg == w.WM_MOUSEHWHEEL);
                return 0;
            },
            w.WM_KEYDOWN, w.WM_SYSKEYDOWN => {
                if (self.onKey(true, wparam, lparam)) return 0;
                return null; // Alt+F4, Alt+Space, F10 menu keys stay with the system
            },
            w.WM_KEYUP, w.WM_SYSKEYUP => {
                if (self.onKey(false, wparam, lparam)) return 0;
                return null;
            },
            w.WM_CHAR => {
                self.onChar(wparam);
                return 0;
            },
            w.WM_SYSCHAR => {
                self.suppress_char = false;
                return null;
            },
            w.WM_SETFOCUS => {
                self.syncModifiers();
                return 0;
            },
            w.WM_KILLFOCUS => {
                self.modifiers = .{};
                return 0;
            },
            w.WM_IME_STARTCOMPOSITION => {
                self.positionIme();
                return null;
            },
            w.WM_IME_COMPOSITION => if (self.onImeComposition(lparam)) return 0,
            w.WM_IME_ENDCOMPOSITION => {
                if (self.input_handler) |h| if (h.vtable.markedTextRange(h.ptr)) |r| {
                    h.vtable.replaceTextInRange(h.ptr, r, "");
                };
                return null;
            },
            w.WM_SETTINGCHANGE => {
                // Top-level broadcast: let the platform re-read appearance once.
                _ = w.SendMessageW(self.plat.hidden, w.WM_SETTINGCHANGE, wparam, lparam);
                return null;
            },
            plat_mod.WM_APP_FRAME_NOW => {
                // This frame also answers a pending vblank request.
                self.frame_requested = false;
                if (self.renderer) |*r| r.sync_interval = 0;
                self.fireRequestFrame(true);
                if (self.renderer) |*r| r.sync_interval = 1;
                // The core may not have drawn (nothing changed): still apply the geometry.
                self.applyPendingRect();
                return 0;
            },
            w.WM_COMMAND, w.WM_HSCROLL, w.WM_VSCROLL, w.WM_NOTIFY => if (self.natives.handleMessage(self, msg, wparam, lparam)) |r| return r,
            w.WM_CTLCOLORSTATIC, w.WM_CTLCOLORBTN, w.WM_CTLCOLOREDIT, w.WM_CTLCOLORLISTBOX => if (self.natives.ctlColor(self, wparam)) |r| return r,
            else => {},
        }
        return null;
    }

    // -----------------------------------------------------------------------------------
    // Teardown
    // -----------------------------------------------------------------------------------

    /// Close: destroy the HWND and everything attached (the core gets `close`).
    pub fn destroyNow(self: *Window) void {
        if (self.closed) return;
        const hwnd = self.hwnd;
        self.teardown();
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
        _ = w.DestroyWindow(hwnd);
        self.finish();
    }

    fn destroyAfterHwnd(self: *Window) void {
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWLP_USERDATA, 0);
        self.teardown();
        self.finish();
    }

    fn teardown(self: *Window) void {
        self.closed = true;
        if (self.pressed != null and w.GetCapture() == self.hwnd) _ = w.ReleaseCapture();
        self.natives.deinit(self);
        if (self.renderer) |*r| r.deinit();
        self.renderer = null;
        self.plat.removeWindow(self);
    }

    fn finish(self: *Window) void {
        if (self.callbacks.close) |f| f(self.callbacks.ctx);
        self.region_rects.deinit(self.gpa);
        self.base_scene.deinit(self.gpa);
        self.overlay_scene.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    // -----------------------------------------------------------------------------------
    // platform.Window vtable
    // -----------------------------------------------------------------------------------

    const vtable: platform.Window.VTable = .{
        .setCallbacks = setCallbacks,
        .bounds = bounds,
        .contentSize = contentSize,
        .resize = resize,
        .scaleFactor = scaleFactor,
        .appearance = appearance,
        .mousePosition = mousePosition,
        .modifiers = modifiersFn,
        .isActive = isActive,
        .isHovered = isHovered,
        .isFullscreen = isFullscreen,
        .isMaximized = isMaximized,
        .setInputHandler = setInputHandler,
        .setTitle = setTitle,
        .setBackgroundAppearance = setBackgroundAppearance,
        .activate = activate,
        .minimize = minimize,
        .zoom = zoom,
        .toggleFullscreen = toggleFullscreen,
        .startWindowMove = startWindowMove,
        .startWindowResize = startWindowResize,
        .setClientInset = setClientInset,
        .requestFrame = requestFrame,
        .draw = draw,
        .spriteAtlas = spriteAtlas,
        .updateImePosition = updateImePosition,
        .close = close,
        .displayId = displayIdFn,
        .attachNativeView = attachNativeView,
        .placeNativeView = placeNativeView,
        .detachNativeView = detachNativeView,
        .focusNativeView = focusNativeView,
        .drawLayered = drawLayered,
        .measureNativeControl = measureNativeControl,
        .attachNativeControl = attachNativeControl,
        .updateNativeControl = updateNativeControl,
        .showContextMenu = showContextMenu,
        .screenBoundsInContent = screenBoundsInContent,
        .setMousePassthrough = setMousePassthrough,
        .setAnchor = setAnchor,
        .setVisible = setVisible,
        .screenMousePosition = screenMousePosition,
        .setInputRegion = setInputRegion,
    };

    fn cast(ptr: *anyopaque) *Window {
        return @ptrCast(@alignCast(ptr));
    }

    fn setCallbacks(ptr: *anyopaque, cbs: platform.WindowCallbacks) void {
        cast(ptr).callbacks = cbs;
    }
    fn bounds(ptr: *anyopaque) Bounds {
        const self = cast(ptr);
        var r: w.RECT = .{};
        _ = w.GetWindowRect(self.hwnd, &r);
        if (self.pending_rect) |p| r = p;
        return plat_mod.rectToLogical(r, self.scale);
    }
    fn contentSize(ptr: *anyopaque) Size {
        return cast(ptr).size;
    }

    fn resize(ptr: *anyopaque, size: Size) void {
        const self = cast(ptr);
        if (size.width <= 0 or size.height <= 0) return;
        if (!self.isOverlay()) {
            var wr: w.RECT = .{};
            _ = w.GetWindowRect(self.hwnd, &wr);
            var cr: w.RECT = .{};
            _ = w.GetClientRect(self.hwnd, &cr);
            var origin: w.POINT = .{};
            _ = w.ClientToScreen(self.hwnd, &origin);
            const saved = self.size;
            self.size = size;
            const r = self.outerRectAt(origin.x, origin.y);
            self.size = saved;
            _ = w.SetWindowPos(self.hwnd, null, 0, 0, r.width(), r.height(), w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
            return;
        }
        // Overlay: keep the anchored corner (or the top-left) fixed; geometry is applied
        // together with the first frame of the new size (see `draw`).
        var current: w.RECT = .{};
        _ = w.GetWindowRect(self.hwnd, &current);
        if (self.pending_rect) |p| current = p;
        _ = self.setSizeAndScale(size, self.scale);
        const dev = self.deviceSize();
        const r: w.RECT = if (self.anchor != null) self.anchoredRect() else .{ .left = current.left, .top = current.top, .right = current.left + dev.width, .bottom = current.top + dev.height };
        if (r.left == current.left and r.top == current.top and r.width() == current.width() and r.height() == current.height()) return;
        self.pending_rect = r;
        if (self.visible) self.frameNow() else self.applyPendingRect();
    }

    fn scaleFactor(ptr: *anyopaque) f32 {
        return cast(ptr).scale;
    }
    fn appearance(ptr: *anyopaque) platform.WindowAppearance {
        return cast(ptr).plat.appearance;
    }
    fn mousePosition(ptr: *anyopaque) Point {
        return cast(ptr).mouse_position;
    }
    fn modifiersFn(ptr: *anyopaque) input.Modifiers {
        return cast(ptr).modifiers;
    }
    fn isActive(ptr: *anyopaque) bool {
        return cast(ptr).active;
    }
    fn isHovered(ptr: *anyopaque) bool {
        return cast(ptr).hovered;
    }
    fn isFullscreen(ptr: *anyopaque) bool {
        return cast(ptr).fullscreen_restore != null;
    }
    fn isMaximized(ptr: *anyopaque) bool {
        return cast(ptr).maximized;
    }
    fn setInputHandler(ptr: *anyopaque, h: ?platform.InputHandler) void {
        cast(ptr).input_handler = h;
    }
    fn setTitle(ptr: *anyopaque, title: []const u8) void {
        const self = cast(ptr);
        const wide = w.utf8ToWide(self.gpa, title) catch return;
        defer self.gpa.free(wide);
        _ = w.SetWindowTextW(self.hwnd, wide.ptr);
    }
    fn setBackgroundAppearance(ptr: *anyopaque, bg: platform.WindowBackgroundAppearance) void {
        // The swapchain's alpha mode is fixed at creation; Mica can be toggled.
        const self = cast(ptr);
        if (self.background == bg) return;
        self.background = bg;
        self.applyDwmAttributes();
        self.requestFrameImpl();
    }
    fn activate(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.isOverlay()) return; // overlays never take focus
        _ = w.ShowWindow(self.hwnd, if (w.IsIconic(self.hwnd) != 0) w.SW_RESTORE else w.SW_SHOW);
        _ = w.SetForegroundWindow(self.hwnd);
    }
    fn minimize(ptr: *anyopaque) void {
        _ = w.ShowWindow(cast(ptr).hwnd, w.SW_MINIMIZE);
    }
    fn zoom(ptr: *anyopaque) void {
        const self = cast(ptr);
        _ = w.ShowWindow(self.hwnd, if (w.IsZoomed(self.hwnd) != 0) w.SW_RESTORE else w.SW_MAXIMIZE);
    }
    fn toggleFullscreen(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.fullscreen_restore) |restore| {
            _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_STYLE, restore.style);
            const r = restore.rect;
            _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOZORDER | w.SWP_FRAMECHANGED | w.SWP_NOACTIVATE);
            self.fullscreen_restore = null;
            return;
        }
        var r: w.RECT = .{};
        _ = w.GetWindowRect(self.hwnd, &r);
        const style = w.GetWindowLongPtrW(self.hwnd, w.GWL_STYLE);
        self.fullscreen_restore = .{ .rect = r, .style = style };
        const mon = w.MonitorFromWindow(self.hwnd, w.MONITOR_DEFAULTTONEAREST) orelse return;
        var info: w.MONITORINFOEXW = .{};
        _ = w.GetMonitorInfoW(mon, &info);
        const frame: isize = w.WS_OVERLAPPEDWINDOW;
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_STYLE, (style & ~frame) | @as(isize, w.WS_POPUP));
        const m = info.rcMonitor;
        _ = w.SetWindowPos(self.hwnd, null, m.left, m.top, m.width(), m.height(), w.SWP_NOZORDER | w.SWP_FRAMECHANGED | w.SWP_NOACTIVATE);
    }
    fn startWindowMove(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.pressed = null;
        _ = w.ReleaseCapture();
        _ = w.SendMessageW(self.hwnd, w.WM_NCLBUTTONDOWN, @intCast(w.HTCAPTION), 0);
    }
    fn startWindowResize(ptr: *anyopaque, edge: platform.ResizeEdge) void {
        const self = cast(ptr);
        const ht: w.LRESULT = switch (edge) {
            .top => w.HTTOP,
            .top_right => w.HTTOPRIGHT,
            .right => w.HTRIGHT,
            .bottom_right => w.HTBOTTOMRIGHT,
            .bottom => w.HTBOTTOM,
            .bottom_left => w.HTBOTTOMLEFT,
            .left => w.HTLEFT,
            .top_left => w.HTTOPLEFT,
        };
        self.pressed = null;
        _ = w.ReleaseCapture();
        _ = w.SendMessageW(self.hwnd, w.WM_NCLBUTTONDOWN, @intCast(ht), 0);
    }
    fn setClientInset(_: *anyopaque, _: f32) void {}
    fn requestFrame(ptr: *anyopaque) void {
        cast(ptr).requestFrameImpl();
    }
    fn draw(ptr: *anyopaque, scene: *const scene_mod.Scene) anyerror!void {
        const self = cast(ptr);
        try self.drawScene(scene);
        self.natives.endFrame(self);
    }
    fn spriteAtlas(ptr: *anyopaque) *atlas_mod.Atlas {
        const self = cast(ptr);
        if (self.renderer) |*r| return r.atlas();
        @panic("window has no renderer");
    }
    fn updateImePosition(ptr: *anyopaque, area: Bounds) void {
        const self = cast(ptr);
        self.ime_area = area;
        self.positionIme();
    }
    fn close(ptr: *anyopaque) void {
        cast(ptr).destroyNow();
    }
    fn displayIdFn(ptr: *anyopaque) ?u32 {
        const self = cast(ptr);
        const mon = w.MonitorFromWindow(self.hwnd, w.MONITOR_DEFAULTTONEAREST) orelse return null;
        var info: w.MONITORINFOEXW = .{};
        if (w.GetMonitorInfoW(mon, &info) == 0) return null;
        return plat_mod.displayId(&info);
    }
    fn screenBoundsInContent(ptr: *anyopaque) ?Bounds {
        const self = cast(ptr);
        const mon = w.MonitorFromWindow(self.hwnd, w.MONITOR_DEFAULTTONEAREST) orelse return null;
        var info: w.MONITORINFOEXW = .{};
        if (w.GetMonitorInfoW(mon, &info) == 0) return null;
        var origin: w.POINT = .{};
        _ = w.ClientToScreen(self.hwnd, &origin);
        const r = info.rcWork;
        return .{
            .origin = .{ .x = @as(f32, @floatFromInt(r.left - origin.x)) / self.scale, .y = @as(f32, @floatFromInt(r.top - origin.y)) / self.scale },
            .size = .{ .width = @as(f32, @floatFromInt(r.width())) / self.scale, .height = @as(f32, @floatFromInt(r.height())) / self.scale },
        };
    }

    // -- native views / controls ---------------------------------------------------------

    fn attachNativeView(ptr: *anyopaque, native: *anyopaque, options: platform.NativeViewOptions) anyerror!platform.NativeViewId {
        const self = cast(ptr);
        return self.natives.attachView(self, @ptrCast(native), options);
    }
    fn placeNativeView(ptr: *anyopaque, view: platform.NativeViewId, placement: ?platform.NativeViewPlacement) void {
        const self = cast(ptr);
        self.natives.place(self, view, placement);
    }
    fn detachNativeView(ptr: *anyopaque, view: platform.NativeViewId) void {
        const self = cast(ptr);
        self.natives.detach(self, view);
    }
    fn focusNativeView(ptr: *anyopaque, view: ?platform.NativeViewId) void {
        const self = cast(ptr);
        self.natives.focus(self, view);
    }
    fn measureNativeControl(ptr: *anyopaque, state: platform.NativeControlState) ?Size {
        const self = cast(ptr);
        return self.natives.measure(self, state);
    }
    fn attachNativeControl(ptr: *anyopaque, state: platform.NativeControlState, z: platform.NativeViewZ) anyerror!platform.NativeViewId {
        const self = cast(ptr);
        return self.natives.attachControl(self, state, z);
    }
    fn updateNativeControl(ptr: *anyopaque, view: platform.NativeViewId, state: platform.NativeControlState) void {
        const self = cast(ptr);
        self.natives.update(self, view, state);
    }

    /// zui `draw_layered`: overlay ranges go to the topmost composition plane, above
    /// the child HWNDs; the rest to the main plane below them.
    fn drawLayered(ptr: *anyopaque, scene: *const scene_mod.Scene, overlay_ranges: []const platform.OverlayRange, capture_input: bool) anyerror!void {
        const self = cast(ptr);
        self.natives.overlay_capture = capture_input and overlay_ranges.len > 0;
        if (overlay_ranges.len == 0) {
            self.overlay_scene.clear(self.gpa);
            try self.drawScene(scene);
            if (self.renderer) |*r| try r.drawOverlay(&self.overlay_scene, self.deviceSizeTyped());
            self.natives.endFrame(self);
            return;
        }
        const gpa = self.gpa;
        self.base_scene.clear(gpa);
        self.overlay_scene.clear(gpa);
        var at: usize = 0;
        const n = scene.len();
        for (overlay_ranges) |r| {
            const start = @min(r.start, n);
            const end = @min(r.end, n);
            if (start > at) try self.base_scene.replay(gpa, at, start, scene);
            if (end > start) try self.overlay_scene.replay(gpa, start, end, scene);
            at = @max(at, end);
        }
        if (n > at) try self.base_scene.replay(gpa, at, n, scene);
        self.base_scene.finish();
        self.overlay_scene.finish();
        try self.drawScene(&self.base_scene);
        if (self.renderer) |*r| if (self.visible) try r.drawOverlay(&self.overlay_scene, self.deviceSizeTyped());
        self.natives.endFrame(self);
    }

    fn deviceSizeTyped(self: *const Window) @import("../../geometry.zig").Size(@import("../../geometry.zig").DevicePixels) {
        const d = self.deviceSize();
        return .{ .width = d.width, .height = d.height };
    }

    // -- context menus ---------------------------------------------------------------------

    fn showContextMenu(ptr: *anyopaque, request: platform.ContextMenuRequest, done: platform.ContextMenuDone) bool {
        const self = cast(ptr);
        const plat = self.plat;
        const menu = w.CreatePopupMenu() orelse return false;
        plat.menu_tags.clearRetainingCapacity();
        buildContextMenu(plat, menu, request.items);
        var pt: w.POINT = .{ .x = @intFromFloat(@round(request.position.x * self.scale)), .y = @intFromFloat(@round(request.position.y * self.scale)) };
        _ = w.ClientToScreen(self.hwnd, &pt);
        // Show after the current event dispatch returns (TrackPopupMenu runs a modal loop).
        const Job = struct {
            win: *Window,
            menu: w.HMENU,
            pt: w.POINT,
            anchor: platform.ContextMenuAnchor,
            done: platform.ContextMenuDone,
            fn run(ctx: *anyopaque) void {
                const job: *@This() = @ptrCast(@alignCast(ctx));
                const gpa = job.win.gpa;
                defer gpa.destroy(job);
                defer _ = w.DestroyMenu(job.menu);
                const p = job.win.plat;
                if (job.win.closed) return job.done.func(job.done.ctx, null);
                const flags: w.UINT = if (job.anchor == .bottom_left) w.TPM_BOTTOMALIGN else 0;
                const id = p.trackMenu(job.menu, job.win.hwnd, job.pt.x, job.pt.y, flags);
                const tag: ?u32 = if (id == 0 or id > p.menu_tags.items.len) null else @intCast(p.menu_tags.items[id - 1]);
                job.done.func(job.done.ctx, tag);
            }
        };
        const job = self.gpa.create(Job) catch {
            _ = w.DestroyMenu(menu);
            return false;
        };
        job.* = .{ .win = self, .menu = menu, .pt = pt, .anchor = request.anchor, .done = done };
        plat.disp.dispatcher().dispatchOnMainThread(.{ .ctx = job, .run = Job.run }, .high);
        return true;
    }

    fn buildContextMenu(plat: *WindowsPlatform, menu: w.HMENU, items: []const platform.ContextMenuItem) void {
        for (items) |item| switch (item.kind) {
            .separator => _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null),
            .header => {
                var buf: [256]u16 = undefined;
                _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.wideBuf(&buf, item.label).ptr);
            },
            .action => {
                plat.menu_tags.append(plat.gpa, item.tag) catch return;
                var label: [300]u8 = undefined;
                const text = if (item.shortcut) |s| std.fmt.bufPrint(&label, "{s}\t{s}{s}{s}{s}", .{
                    item.label,
                    if (s.modifiers.control) "Ctrl+" else "",
                    if (s.modifiers.alt) "Alt+" else "",
                    if (s.modifiers.shift) "Shift+" else "",
                    s.key,
                }) catch item.label else item.label;
                var buf: [320]u16 = undefined;
                var flags: w.UINT = w.MF_STRING;
                if (item.check != .off) flags |= w.MF_CHECKED;
                if (item.disabled) flags |= w.MF_GRAYED;
                _ = w.AppendMenuW(menu, flags, plat.menu_tags.items.len, w.wideBuf(&buf, text).ptr);
            },
            .submenu => {
                const sub = w.CreatePopupMenu() orelse continue;
                buildContextMenu(plat, sub, item.children);
                var buf: [256]u16 = undefined;
                _ = w.AppendMenuW(menu, w.MF_POPUP | (if (item.disabled) w.MF_GRAYED else 0), @intFromPtr(sub), w.wideBuf(&buf, item.label).ptr);
            },
        };
    }

    // -- desktop overlay (docs/DESKTOP_OVERLAY.md) -------------------------------------

    fn setMousePassthrough(ptr: *anyopaque, on: bool) void {
        const self = cast(ptr);
        self.passthrough = on;
        if (self.isOverlay()) {
            self.refreshTransparency();
            return;
        }
        // Other windows: WS_EX_LAYERED | WS_EX_TRANSPARENT.
        var ex = w.GetWindowLongPtrW(self.hwnd, w.GWL_EXSTYLE);
        const bits: isize = w.WS_EX_TRANSPARENT | w.WS_EX_LAYERED;
        ex = if (on) ex | bits else ex & ~@as(isize, w.WS_EX_TRANSPARENT);
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWL_EXSTYLE, ex);
        if (on) _ = w.SetLayeredWindowAttributes(self.hwnd, 0, 255, w.LWA_ALPHA);
    }

    fn setAnchor(ptr: *anyopaque, anchor: platform.OverlayAnchor, display_id: ?u32) void {
        const self = cast(ptr);
        self.anchor = anchor;
        self.anchor_display = display_id;
        const mon = self.anchorMonitor() orelse return;
        const dpi = plat_mod.monitorDpi(mon);
        if (dpi != self.dpi) {
            // Moving to a monitor with another scale: WM_DPICHANGED re-anchors.
            self.dpi = dpi;
        }
        const r = self.anchoredRectOn(mon);
        self.pending_rect = null;
        _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        self.origin = .{ .x = @as(f32, @floatFromInt(r.left)) / self.scale, .y = @as(f32, @floatFromInt(r.top)) / self.scale };
    }

    fn setVisible(ptr: *anyopaque, visible: bool) void {
        const self = cast(ptr);
        if (self.visible == visible) return;
        self.visible = visible;
        if (visible) {
            if (self.isOverlay()) {
                if (self.anchor != null) {
                    const r = self.anchoredRect();
                    _ = w.SetWindowPos(self.hwnd, w.hwndFromInt(w.HWND_TOPMOST), r.left, r.top, r.width(), r.height(), w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW);
                } else _ = w.ShowWindow(self.hwnd, w.SW_SHOWNOACTIVATE);
            } else _ = w.ShowWindow(self.hwnd, w.SW_SHOW);
            self.frame_requested = false;
            self.requestFrameImpl();
        } else {
            if (self.pressed != null and w.GetCapture() == self.hwnd) _ = w.ReleaseCapture();
            _ = w.ShowWindow(self.hwnd, w.SW_HIDE);
            self.frame_requested = false;
            // Hidden windows hold no swapchain / intermediate GPU memory.
            if (self.renderer) |*r| r.suspendTargets();
            self.presented = false;
        }
        self.plat.updateHooks();
    }

    fn screenMousePosition(ptr: *anyopaque) ?Point {
        const self = cast(ptr);
        var pt: w.POINT = .{};
        _ = w.GetCursorPos(&pt);
        // Same logical space as `bounds()` (physical / this window's scale).
        return .{ .x = @as(f32, @floatFromInt(pt.x)) / self.scale, .y = @as(f32, @floatFromInt(pt.y)) / self.scale };
    }

    fn setInputRegion(ptr: *anyopaque, rects: ?[]const Bounds) void {
        const self = cast(ptr);
        if (rects) |rs| {
            self.region_rects.clearRetainingCapacity();
            self.region_rects.appendSlice(self.gpa, rs) catch {
                self.region = .all;
                return;
            };
            self.region = if (rs.len == 0) .none else .rects;
        } else self.region = .all;
        self.refreshTransparency();
    }
};

fn wndProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (msg == w.WM_NCCREATE) {
        const cs: *const w.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |p| {
            const self: *Window = @ptrCast(@alignCast(p));
            self.hwnd = hwnd;
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(p)));
        }
        return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (raw == 0) return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(raw)));
    if (self.closed) return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    if (self.handleMessage(msg, wparam, lparam)) |r| return r;
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}
