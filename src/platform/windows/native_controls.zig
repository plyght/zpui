//! Windows native form controls (`zpui.nativeSwitch` & co., `platform.NativeControlState`)
//! and foreign native child views, as child HWNDs of a zpui window:
//!
//! | kind      | control                                                        |
//! |-----------|----------------------------------------------------------------|
//! | switch_   | `BUTTON` `BS_AUTOCHECKBOX` (no text; Win32 has no toggle)      |
//! | checkbox  | `BUTTON` `BS_AUTOCHECKBOX` with its title                      |
//! | slider    | `msctls_trackbar32` (`TBS_HORZ | TBS_NOTICKS`)                 |
//! | segmented | a row of `BS_AUTORADIOBUTTON | BS_PUSHLIKE` buttons in a host  |
//! | popup     | `COMBOBOX` `CBS_DROPDOWNLIST`                                   |
//! | stepper   | `msctls_updown32` (no buddy; the value lives here)             |
//!
//! Controls are comctl32 v6 (themed): the executable's manifest or, without one, the
//! platform's activation context borrowed from shell32 is active while they are
//! created. Dark mode uses the `DarkMode_Explorer` / `DarkMode_CFD` themes plus
//! `WM_CTLCOLOR*` text colors. Children are clipped to the visible region with a window
//! region and stack between the window's two composition planes: above zpui's main
//! surface, below the overlay plane (menus, popovers, dialogs). While the overlay plane
//! holds interactive content (`drawLayered(capture_input = true)`) the children answer
//! `HTTRANSPARENT`, so clicks reach zpui. Programmatic updates never report back.

const std = @import("std");
const platform = @import("../platform.zig");
const w = @import("win32.zig");
const plat_mod = @import("windows.zig");
const window_mod = @import("window.zig");

const Window = window_mod.Window;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const Size = platform.Size;

const slider_range: i32 = 1000;
const stepper_center: i32 = 50;
const combo_dropdown_height: i32 = 240;

const Entry = struct {
    host: *Host,
    id: platform.NativeViewId,
    hwnd: w.HWND,
    kind: ?platform.NativeControlKind,
    /// Segmented: the buttons inside `hwnd`.
    buttons: std.ArrayList(w.HWND) = .empty,
    orig_proc: ?w.WNDPROC = null,
    orig_button_proc: ?w.WNDPROC = null,
    owned: bool = true,
    dark: ?bool = null,
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 0,
    value: f64 = 0,
    last: ?platform.NativeViewPlacement = null,
};

pub const Host = struct {
    entries: std.ArrayList(*Entry) = .empty,
    next_id: u32 = 1,
    /// The overlay plane takes the mouse: children are click-through.
    overlay_capture: bool = false,
    font: ?w.HFONT = null,
    font_dpi: u32 = 0,
    measure_font: ?w.HFONT = null,
    brush: ?w.HBRUSH = null,
    brush_dark: bool = false,
    /// Suppresses notifications while applying programmatic state.
    updating: bool = false,

    pub fn deinit(self: *Host, win: *Window) void {
        for (self.entries.items) |e| self.destroyEntry(win, e);
        self.entries.deinit(win.gpa);
        if (self.font) |f| _ = w.DeleteObject(@ptrCast(f));
        if (self.measure_font) |f| _ = w.DeleteObject(@ptrCast(f));
        if (self.brush) |b| _ = w.DeleteObject(@ptrCast(b));
        self.* = .{};
    }

    fn find(self: *Host, id: platform.NativeViewId) ?*Entry {
        for (self.entries.items) |e| if (e.id == id) return e;
        return null;
    }

    fn findHwnd(self: *Host, hwnd: w.HWND) ?*Entry {
        for (self.entries.items) |e| {
            if (e.hwnd == hwnd) return e;
        }
        return null;
    }

    fn destroyEntry(_: *Host, win: *Window, e: *Entry) void {
        if (w.IsWindow(e.hwnd) != 0) {
            if (e.owned) {
                _ = w.DestroyWindow(e.hwnd);
            } else {
                if (e.orig_proc) |p| _ = w.SetWindowLongPtrW(e.hwnd, w.GWLP_WNDPROC, @bitCast(@intFromPtr(p)));
                _ = w.ShowWindow(e.hwnd, w.SW_HIDE);
                _ = w.SetParent(e.hwnd, null);
            }
        }
        e.buttons.deinit(win.gpa);
        win.gpa.destroy(e);
    }

    // -- fonts / colors --------------------------------------------------------------

    fn messageFont(dpi: u32) ?w.HFONT {
        var ncm: w.NONCLIENTMETRICSW = .{};
        if (w.SystemParametersInfoForDpi(w.SPI_GETNONCLIENTMETRICS, @sizeOf(w.NONCLIENTMETRICSW), &ncm, 0, dpi) == 0) return null;
        return w.CreateFontIndirectW(&ncm.lfMessageFont);
    }

    fn controlFont(self: *Host, win: *Window) ?w.HFONT {
        if (self.font == null or self.font_dpi != win.dpi) {
            if (self.font) |f| _ = w.DeleteObject(@ptrCast(f));
            self.font = messageFont(win.dpi);
            self.font_dpi = win.dpi;
        }
        return self.font;
    }

    fn setFont(self: *Host, win: *Window, hwnd: w.HWND) void {
        if (self.controlFont(win)) |f| _ = w.SendMessageW(hwnd, w.WM_SETFONT, @intFromPtr(f), 1);
    }

    pub fn onDpiChanged(self: *Host, win: *Window) void {
        for (self.entries.items) |e| {
            if (e.kind == null) continue;
            self.setFont(win, e.hwnd);
            for (e.buttons.items) |b| self.setFont(win, b);
            e.last = null; // re-place at the new scale on the next frame
        }
    }

    pub fn onAppearance(self: *Host, win: *Window) void {
        for (self.entries.items) |e| if (e.kind != null) applyTheme(win, e);
        for (self.entries.items) |e| _ = w.InvalidateRect(e.hwnd, null, w.TRUE);
    }

    fn isDark(win: *Window, e: *const Entry) bool {
        return e.dark orelse win.isDark();
    }

    fn applyTheme(win: *Window, e: *Entry) void {
        const dark = isDark(win, e);
        const theme: ?w.LPCWSTR = if (e.kind == .popup)
            (if (dark) L("DarkMode_CFD") else L("CFD"))
        else if (dark) L("DarkMode_Explorer") else L("Explorer");
        _ = w.SetWindowTheme(e.hwnd, theme, null);
        for (e.buttons.items) |b| _ = w.SetWindowTheme(b, theme, null);
    }

    fn backgroundRgb(dark: bool) w.DWORD {
        return if (dark) 0x001F1F1F else 0x00FAFAFA;
    }

    /// WM_CTLCOLOR*: readable text on the window's background in both themes.
    pub fn ctlColor(self: *Host, win: *Window, wparam: w.WPARAM) ?w.LRESULT {
        if (self.entries.items.len == 0) return null;
        const dark = win.isDark();
        const hdc: w.HDC = @ptrFromInt(wparam);
        _ = w.SetTextColor(hdc, if (dark) 0x00F0F0F0 else 0x00202020);
        _ = w.SetBkColor(hdc, backgroundRgb(dark));
        _ = w.SetBkMode(hdc, w.TRANSPARENT);
        if (self.brush == null or self.brush_dark != dark) {
            if (self.brush) |b| _ = w.DeleteObject(@ptrCast(b));
            self.brush = w.CreateSolidBrush(backgroundRgb(dark));
            self.brush_dark = dark;
        }
        return @bitCast(@intFromPtr(self.brush));
    }

    // -- measuring -----------------------------------------------------------------------

    fn textWidth(self: *Host, s: []const u8) f32 {
        if (s.len == 0) return 0;
        if (self.measure_font == null) self.measure_font = messageFont(96);
        const dc = w.GetDC(null) orelse return @floatFromInt(s.len * 7);
        defer _ = w.ReleaseDC(null, dc);
        const old = if (self.measure_font) |f| w.SelectObject(dc, @ptrCast(f)) else null;
        defer if (old) |o| {
            _ = w.SelectObject(dc, o);
        };
        var buf: [256]u16 = undefined;
        const wide = w.wideBuf(&buf, s);
        var sz: w.SIZE = .{};
        _ = w.GetTextExtentPoint32W(dc, wide.ptr, @intCast(wide.len), &sz);
        return @floatFromInt(sz.cx);
    }

    /// Logical frame size of the control for `state` (0 = no preference).
    pub fn measure(self: *Host, _: *Window, state: platform.NativeControlState) ?Size {
        const shrink: f32 = switch (state.size) {
            .small => 2,
            .mini => 4,
            else => 0,
        };
        return switch (state.kind) {
            .switch_ => .{ .width = 18, .height = 20 - shrink },
            .checkbox => .{ .width = 20 + (if (state.title.len > 0) 4 + self.textWidth(state.title) else 0), .height = 20 - shrink },
            .slider => .{ .width = 0, .height = 26 - shrink },
            .segmented => blk: {
                var total: f32 = 0;
                for (state.items) |it| total += @max(self.textWidth(it) + 24, 40);
                break :blk .{ .width = @max(total, 40), .height = 26 - shrink };
            },
            .popup => blk: {
                var widest: f32 = 0;
                for (state.items) |it| widest = @max(widest, self.textWidth(it));
                break :blk .{ .width = widest + 40, .height = 24 - shrink };
            },
            .stepper => .{ .width = 18, .height = 24 - shrink },
        };
    }

    // -- attach / update -----------------------------------------------------------------

    fn newId(self: *Host) platform.NativeViewId {
        defer self.next_id += 1;
        return @fromBackingInt(@intCast(self.next_id));
    }

    fn createChild(win: *Window, class: w.LPCWSTR, text: ?w.LPCWSTR, style: w.DWORD, parent: w.HWND, id: usize) ?w.HWND {
        const cookie = plat_mod.activateControlsContext(win.plat);
        defer plat_mod.deactivateControlsContext(cookie);
        return w.CreateWindowExW(0, class, text, w.WS_CHILD | w.WS_CLIPSIBLINGS | style, 0, 0, 10, 10, parent, @ptrFromInt(id), win.plat.hinstance, null);
    }

    pub fn attachControl(self: *Host, win: *Window, state: platform.NativeControlState, z: platform.NativeViewZ) !platform.NativeViewId {
        _ = z; // every child sits between the two composition planes
        const id = self.newId();
        const e = try win.gpa.create(Entry);
        errdefer win.gpa.destroy(e);
        const ctrl_id: usize = @backingInt(id);
        const hwnd: w.HWND = switch (state.kind) {
            .switch_, .checkbox => createChild(win, L("BUTTON"), null, w.BS_AUTOCHECKBOX | w.WS_TABSTOP, win.hwnd, ctrl_id),
            .slider => createChild(win, L("msctls_trackbar32"), null, w.TBS_HORZ | w.TBS_NOTICKS | w.WS_TABSTOP, win.hwnd, ctrl_id),
            .segmented => blk: {
                registerSegmentedClass(win.plat.hinstance);
                break :blk createChild(win, segmented_class, null, w.WS_CLIPCHILDREN, win.hwnd, ctrl_id);
            },
            .popup => createChild(win, L("COMBOBOX"), null, w.CBS_DROPDOWNLIST | w.CBS_HASSTRINGS | w.WS_TABSTOP | 0x00200000, win.hwnd, ctrl_id), // WS_VSCROLL
            .stepper => createChild(win, L("msctls_updown32"), null, w.UDS_ARROWKEYS, win.hwnd, ctrl_id),
        } orelse return error.NativeControlCreationFailed;
        e.* = .{ .host = self, .id = id, .hwnd = hwnd, .kind = state.kind };
        // Our entry rides in GWLP_USERDATA; the subclass makes children click-through
        // while the overlay plane captures input.
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(e)));
        if (state.kind != .segmented) {
            e.orig_proc = @ptrFromInt(@as(usize, @bitCast(w.SetWindowLongPtrW(hwnd, w.GWLP_WNDPROC, @bitCast(@intFromPtr(&childProc))))));
        }
        if (state.kind == .stepper) {
            _ = w.SendMessageW(hwnd, w.UDM_SETRANGE32, 0, 100);
            _ = w.SendMessageW(hwnd, w.UDM_SETPOS32, 0, stepper_center);
        }
        self.setFont(win, hwnd);
        try self.entries.append(win.gpa, e);
        self.apply(win, e, state);
        return id;
    }

    pub fn attachView(self: *Host, win: *Window, hwnd: w.HWND, options: platform.NativeViewOptions) !platform.NativeViewId {
        _ = options;
        const id = self.newId();
        const e = try win.gpa.create(Entry);
        errdefer win.gpa.destroy(e);
        e.* = .{ .host = self, .id = id, .hwnd = hwnd, .kind = null, .owned = false };
        const style = w.GetWindowLongPtrW(hwnd, w.GWL_STYLE);
        const popup: isize = @bitCast(@as(usize, w.WS_POPUP));
        _ = w.SetWindowLongPtrW(hwnd, w.GWL_STYLE, (style & ~popup) | @as(isize, w.WS_CHILD | w.WS_CLIPSIBLINGS));
        _ = w.SetParent(hwnd, win.hwnd);
        _ = w.ShowWindow(hwnd, w.SW_HIDE);
        try self.entries.append(win.gpa, e);
        return id;
    }

    pub fn update(self: *Host, win: *Window, view: platform.NativeViewId, state: platform.NativeControlState) void {
        const e = self.find(view) orelse return;
        if (e.kind == null) return;
        self.apply(win, e, state);
    }

    fn apply(self: *Host, win: *Window, e: *Entry, state: platform.NativeControlState) void {
        self.updating = true;
        defer self.updating = false;
        const hwnd = e.hwnd;
        _ = w.EnableWindow(hwnd, @intFromBool(state.enabled));
        if (e.dark != state.dark or e.last == null) {
            e.dark = state.dark;
            applyTheme(win, e);
        }
        e.min = state.min;
        e.max = state.max;
        e.step = state.step;
        e.value = state.value;
        var buf: [256]u16 = undefined;
        switch (state.kind) {
            .switch_, .checkbox => {
                const text = if (state.kind == .checkbox) (if (state.title.len > 0) state.title else state.label) else "";
                _ = w.SetWindowTextW(hwnd, w.wideBuf(&buf, text).ptr);
                _ = w.SendMessageW(hwnd, w.BM_SETCHECK, if (state.on) w.BST_CHECKED else w.BST_UNCHECKED, 0);
            },
            .slider => {
                const range: i32 = if (state.step > 0 and state.max > state.min)
                    @intFromFloat(@min(@round((state.max - state.min) / state.step), 10000))
                else
                    slider_range;
                _ = w.SendMessageW(hwnd, w.TBM_SETRANGEMIN, 0, 0);
                _ = w.SendMessageW(hwnd, w.TBM_SETRANGEMAX, 0, range);
                _ = w.SendMessageW(hwnd, w.TBM_SETPAGESIZE, 0, @max(@divTrunc(range, 10), 1));
                _ = w.SendMessageW(hwnd, w.TBM_SETPOS, 1, sliderPos(state.value, state.min, state.max, range));
            },
            .popup => {
                _ = w.SendMessageW(hwnd, w.CB_RESETCONTENT, 0, 0);
                for (state.items) |it| _ = w.SendMessageW(hwnd, w.CB_ADDSTRING, 0, @bitCast(@intFromPtr(w.wideBuf(&buf, it).ptr)));
                const sel: isize = if (state.selected) |s| @intCast(s) else -1;
                _ = w.SendMessageW(hwnd, w.CB_SETCURSEL, @bitCast(sel), 0);
            },
            .segmented => self.applySegments(win, e, state),
            .stepper => {},
        }
    }

    fn sliderPos(value: f64, min: f64, max: f64, range: i32) isize {
        if (max <= min) return 0;
        const t = std.math.clamp((value - min) / (max - min), 0, 1);
        return @intFromFloat(@round(t * @as(f64, @floatFromInt(range))));
    }

    fn applySegments(self: *Host, win: *Window, e: *Entry, state: platform.NativeControlState) void {
        var buf: [256]u16 = undefined;
        // Rebuild when the item count changes; otherwise relabel.
        if (e.buttons.items.len != state.items.len) {
            for (e.buttons.items) |b| _ = w.DestroyWindow(b);
            e.buttons.clearRetainingCapacity();
            for (state.items, 0..) |_, i| {
                const style: w.DWORD = w.BS_AUTORADIOBUTTON | w.BS_PUSHLIKE | w.WS_VISIBLE | (if (i == 0) w.WS_GROUP | w.WS_TABSTOP else 0);
                const b = createChild(win, L("BUTTON"), null, style, e.hwnd, 100 + i) orelse continue;
                _ = w.SetWindowLongPtrW(b, w.GWLP_USERDATA, @bitCast(@intFromPtr(e)));
                const prev: w.WNDPROC = @ptrFromInt(@as(usize, @bitCast(w.SetWindowLongPtrW(b, w.GWLP_WNDPROC, @bitCast(@intFromPtr(&childProc))))));
                e.orig_button_proc = prev;
                self.setFont(win, b);
                e.buttons.append(win.gpa, b) catch break;
            }
            applyTheme(win, e);
            e.last = null;
        }
        for (e.buttons.items, 0..) |b, i| {
            _ = w.SetWindowTextW(b, w.wideBuf(&buf, state.items[i]).ptr);
            const on = state.selected != null and state.selected.? == i;
            _ = w.SendMessageW(b, w.BM_SETCHECK, if (on) w.BST_CHECKED else w.BST_UNCHECKED, 0);
            _ = w.EnableWindow(b, @intFromBool(state.enabled));
        }
    }

    // -- placement -----------------------------------------------------------------------

    pub fn place(self: *Host, win: *Window, view: platform.NativeViewId, placement: ?platform.NativeViewPlacement) void {
        const e = self.find(view) orelse return;
        const p = placement orelse {
            if (e.last != null) _ = w.ShowWindow(e.hwnd, w.SW_HIDE);
            e.last = null;
            return;
        };
        if (e.last) |l| if (std.meta.eql(l, p)) return;
        e.last = p;
        const s = win.scale;
        const x: i32 = @intFromFloat(@round(p.bounds.origin.x * s));
        const y: i32 = @intFromFloat(@round(p.bounds.origin.y * s));
        const cw: i32 = @intFromFloat(@max(1, @round(p.bounds.size.width * s)));
        var ch: i32 = @intFromFloat(@max(1, @round(p.bounds.size.height * s)));
        const visible = p.clip.size.width > 0 and p.clip.size.height > 0;
        if (e.kind == .popup) ch += @intFromFloat(@as(f32, @floatFromInt(combo_dropdown_height)) * s);
        _ = w.SetWindowPos(e.hwnd, null, x, y, cw, ch, w.SWP_NOZORDER | w.SWP_NOACTIVATE | (if (visible) w.SWP_SHOWWINDOW else w.SWP_HIDEWINDOW));
        if (e.kind == .segmented) layoutSegments(e, cw, ch);
        // Clip to the visible region (scrolling containers).
        const clipped = p.clip.origin.x != p.bounds.origin.x or p.clip.origin.y != p.bounds.origin.y or
            p.clip.size.width != p.bounds.size.width or p.clip.size.height != p.bounds.size.height;
        if (clipped and visible) {
            const l: i32 = @intFromFloat(@round((p.clip.origin.x - p.bounds.origin.x) * s));
            const t: i32 = @intFromFloat(@round((p.clip.origin.y - p.bounds.origin.y) * s));
            const r = l + @as(i32, @intFromFloat(@round(p.clip.size.width * s)));
            const b = t + @as(i32, @intFromFloat(@round(p.clip.size.height * s)));
            _ = w.SetWindowRgn(e.hwnd, w.CreateRectRgn(l, t, r, b), w.TRUE);
        } else _ = w.SetWindowRgn(e.hwnd, null, w.TRUE);
    }

    fn layoutSegments(e: *Entry, width: i32, height: i32) void {
        const n: i32 = @intCast(e.buttons.items.len);
        if (n == 0) return;
        for (e.buttons.items, 0..) |b, i| {
            const ii: i32 = @intCast(i);
            const x0 = @divTrunc(width * ii, n);
            const x1 = @divTrunc(width * (ii + 1), n);
            _ = w.SetWindowPos(b, null, x0, 0, x1 - x0, height, w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        }
    }

    pub fn detach(self: *Host, win: *Window, view: platform.NativeViewId) void {
        for (self.entries.items, 0..) |e, i| if (e.id == view) {
            _ = self.entries.swapRemove(i);
            self.destroyEntry(win, e);
            return;
        };
    }

    pub fn focus(self: *Host, win: *Window, view: ?platform.NativeViewId) void {
        if (view) |v| if (self.find(v)) |e| {
            _ = w.SetFocus(if (e.buttons.items.len > 0) e.buttons.items[0] else e.hwnd);
            return;
        };
        _ = w.SetFocus(win.hwnd);
    }

    pub fn endFrame(_: *Host, _: *Window) void {}

    // -- notifications -------------------------------------------------------------------

    fn report(win: *Window, e: *Entry, event: platform.NativeControlEvent) void {
        if (e.host.updating) return;
        const f = win.callbacks.native_control orelse return;
        f(win.callbacks.ctx, e.id, event);
    }

    /// WM_COMMAND / WM_HSCROLL / WM_NOTIFY on the zpui window.
    pub fn handleMessage(self: *Host, win: *Window, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) ?w.LRESULT {
        if (msg == w.WM_NOTIFY) {
            const hdr: *const w.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const from = hdr.hwndFrom orelse return null;
            const e = self.findHwnd(from) orelse return null;
            if (e.kind != .stepper or hdr.code != w.UDN_DELTAPOS) return null;
            const nm: *const w.NMUPDOWN = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const step = if (e.step > 0) e.step else 1;
            const next = std.math.clamp(e.value + @as(f64, @floatFromInt(nm.iDelta)) * step, @min(e.min, e.max), @max(e.min, e.max));
            if (next != e.value) {
                e.value = next;
                report(win, e, .{ .kind = .stepper, .value = next });
            }
            return 1; // keep the control's own position centered
        }
        if (lparam == 0) return null;
        const child: w.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const e = self.findHwnd(child) orelse return null;
        switch (msg) {
            w.WM_COMMAND => {
                const code = w.hiword(@as(isize, @bitCast(wparam)));
                switch (e.kind orelse return null) {
                    .switch_, .checkbox => if (code == w.BN_CLICKED) {
                        const on = w.SendMessageW(e.hwnd, w.BM_GETCHECK, 0, 0) == w.BST_CHECKED;
                        report(win, e, .{ .kind = e.kind.?, .on = on });
                        return 0;
                    },
                    .popup => if (code == w.CBN_SELCHANGE) {
                        const sel = w.SendMessageW(e.hwnd, w.CB_GETCURSEL, 0, 0);
                        if (sel >= 0) report(win, e, .{ .kind = .popup, .index = @intCast(sel) });
                        return 0;
                    },
                    else => {},
                }
            },
            w.WM_HSCROLL, w.WM_VSCROLL => if (e.kind == .slider) {
                const pos: f64 = @floatFromInt(w.SendMessageW(e.hwnd, w.TBM_GETPOS, 0, 0));
                const range: f64 = if (e.step > 0 and e.max > e.min) @round((e.max - e.min) / e.step) else @floatFromInt(slider_range);
                const value = if (range > 0) e.min + (e.max - e.min) * pos / range else e.min;
                if (value != e.value) {
                    e.value = value;
                    report(win, e, .{ .kind = .slider, .value = value });
                }
                return 0;
            },
            else => {},
        }
        return null;
    }
};

// ---- subclass + segmented host --------------------------------------------------------

fn childProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    const e: *Entry = @ptrFromInt(@as(usize, @bitCast(raw)));
    if (msg == w.WM_NCHITTEST and e.host.overlay_capture) return w.HTTRANSPARENT;
    const is_button = e.kind == .segmented;
    const orig = (if (is_button) e.orig_button_proc else e.orig_proc) orelse return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    return w.CallWindowProcW(orig, hwnd, msg, wparam, lparam);
}

const segmented_class = L("zpui_segmented");
var segmented_registered = false;

fn registerSegmentedClass(hinstance: w.HINSTANCE) void {
    if (segmented_registered) return;
    segmented_registered = true;
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = segmentedProc, .hInstance = hinstance, .lpszClassName = segmented_class });
}

fn segmentedProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (raw == 0) return w.DefWindowProcW(hwnd, msg, wparam, lparam);
    const e: *Entry = @ptrFromInt(@as(usize, @bitCast(raw)));
    switch (msg) {
        w.WM_NCHITTEST => if (e.host.overlay_capture) return w.HTTRANSPARENT,
        w.WM_ERASEBKGND => return 1,
        w.WM_COMMAND => if (w.hiword(@as(isize, @bitCast(wparam))) == w.BN_CLICKED and lparam != 0) {
            const button: w.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            for (e.buttons.items, 0..) |b, i| if (b == button) {
                const parent = w.GetParent(hwnd) orelse return 0;
                const wraw = w.GetWindowLongPtrW(parent, w.GWLP_USERDATA);
                if (wraw == 0) return 0;
                const win: *Window = @ptrFromInt(@as(usize, @bitCast(wraw)));
                Host.report(win, e, .{ .kind = .segmented, .index = @intCast(i) });
                return 0;
            };
        },
        w.WM_CTLCOLORBTN, w.WM_CTLCOLORSTATIC => {
            // Forward to the zpui window for theme colors.
            const parent = w.GetParent(hwnd) orelse return 0;
            return w.SendMessageW(parent, msg, wparam, lparam);
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}
