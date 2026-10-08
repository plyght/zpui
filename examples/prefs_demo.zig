//! Preferences window demo (`zig build prefs-demo`): every native-control kind plus an
//! editable "only show in these apps" list, laid out once with `zpui.prefs` and shown in
//! the desktop's own look — libadwaita on GNOME (and by default), Breeze on KDE Plasma,
//! a System Settings form with real AppKit controls on macOS.
//!
//! Environment:
//!   ZPUI_DESKTOP_STYLE=gnome|kde      force the Linux look (else XDG_CURRENT_DESKTOP)
//!   ZPUI_PREFS_APPEARANCE=light|dark  force light / dark (else the system appearance)
//!   ZPUI_PREFS_ACCENT=RRGGBB          force the accent (else the settings portal)
//!   ZPUI_PREFS_OPEN=popup             open the drop-down list (screenshots)
//!   ZPUI_SMOKE_FRAMES=N               render N frames, capture the window to
//!                                     zig-out/prefs-demo.png (ZPUI_SMOKE_OUT=path), exit
//!                                     (Linux: X11 + ImageMagick `import`, e.g. under Xvfb;
//!                                     macOS: CGWindowListCreateImage)

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const png = @import("png.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const prefs = zpui.prefs;

const accents = [_][]const u8{ "Blue", "Teal", "Green", "Yellow", "Orange", "Red", "Pink", "Purple", "Slate" };
const densities = [_][]const u8{ "Compact", "Default", "Spacious" };
const positions = [_][]const u8{ "Top", "Bottom" };

const AppEntry = struct { name: []const u8, id: []const u8, color: u32 };
const catalog = [_]AppEntry{
    .{ .name = "Text Editor", .id = "org.gnome.TextEditor", .color = 0xe5a50a },
    .{ .name = "Terminal", .id = "org.gnome.Console", .color = 0x3d3846 },
    .{ .name = "Files", .id = "org.gnome.Nautilus", .color = 0x3584e4 },
    .{ .name = "Web", .id = "org.gnome.Epiphany", .color = 0x2190a4 },
    .{ .name = "Calendar", .id = "org.gnome.Calendar", .color = 0xe01b24 },
    .{ .name = "Builder", .id = "org.gnome.Builder", .color = 0x9141ac },
};

const Prefs = struct {
    enabled: bool = true,
    dark_style: bool = false,
    accent: u32 = 0,
    text_scale: f64 = 0.4,
    density: u32 = 1,
    position: u32 = 0,
    at_login: bool = true,
    sounds: bool = false,
    delay: f64 = 3,
    apps: [catalog.len]bool = .{ true, true, false, true, false, false },
    selected: ?u32 = 0,
    items: [catalog.len]prefs.ListItem = undefined,
    item_ix: [catalog.len]u32 = undefined,

    pub fn render(self: *Prefs, window: *Window, cx: *Context(Prefs)) zpui.Div {
        const look = prefs.lookFor(window);
        // The visible apps (frame-lived slice; the icons are drawn tiles).
        var n: usize = 0;
        for (catalog, 0..) |e, i| if (self.apps[i]) {
            self.items[n] = .{ .title = e.name, .subtitle = e.id, .icon = zpui.intoAnyElement(appIcon(e)) };
            self.item_ix[n] = @intCast(i);
            n += 1;
        };
        const sel = if (self.selected) |s| (if (s < n) s else null) else null;
        return div().size(zpui.relative(1)).flex().flexCol().bg(look.window_bg)
            .child(prefs.headerBar(window, look, "Preferences"))
            .child(div().flex1().minH(px(0)).child(prefs.page(window, look, &.{
            .{ .title = "General", .rows = &.{
                prefs.row("Enable Overlay", "Show the overlay when the shortcut is pressed", zpui.nativeSwitch("enabled", .{ .on = self.enabled, .label = "Enable Overlay" }, cx.listener(Prefs.onEnabled), null)),
                prefs.row("Launch at Login", "", zpui.nativeCheckbox("login", .{ .on = self.at_login, .label = "Launch at Login" }, cx.listener(Prefs.onLogin), null)),
                prefs.row("Hide Delay", "Seconds before the overlay hides", zpui.nativeStepper("delay", .{ .value = self.delay, .min = 0, .max = 30, .step = 1, .label = "Hide Delay" }, cx.listener(Prefs.onDelay), null)),
                prefs.row("Play Sounds", "Unavailable while Do Not Disturb is on", zpui.nativeSwitch("sounds", .{ .on = self.sounds, .enabled = false, .label = "Play Sounds" }, null, null)),
            } },
            .{ .title = "Appearance", .description = "How the overlay looks on screen", .rows = &.{
                prefs.row("Dark Style", "", zpui.nativeSwitch("dark", .{ .on = self.dark_style, .label = "Dark Style" }, cx.listener(Prefs.onDark), null)),
                prefs.row("Accent Color", "", zpui.nativePopup("accent", .{ .items = &accents, .selected = self.accent, .label = "Accent Color", .width = px(140) }, cx.listener(Prefs.onAccent), null)),
                prefs.row("Text Size", "", zpui.nativeSlider("scale", .{ .value = self.text_scale, .label = "Text Size", .width = px(200) }, cx.listener(Prefs.onScale), null)),
                prefs.row("Density", "", zpui.nativeSegmented("density", .{ .items = &densities, .selected = self.density, .label = "Density" }, cx.listener(Prefs.onDensity), null)),
                prefs.row("Position", "", zpui.nativeSegmented("position", .{ .items = &positions, .selected = self.position, .label = "Position" }, cx.listener(Prefs.onPosition), null)),
            } },
            .{ .title = "Only Show in These Apps", .description = "The overlay stays hidden in every other app", .content = prefs.editableList(look, "apps", .{
                .items = self.items[0..n],
                .selected = sel,
                .label = "Apps",
            }, cx.listener(Prefs.onApps)) },
        })));
    }

    fn appIcon(e: AppEntry) zpui.Div {
        return div().size(zpui.relative(1)).rounded(px(6)).bg(zpui.rgb(e.color).toHsla()).flex().itemsCenter().justifyCenter()
            .textColor(zpui.rgb(0xffffff).toHsla()).fontWeight(700).textSize(px(12)).child(e.name[0..1]);
    }

    fn onEnabled(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.enabled = ev.on;
        cx.notify();
    }
    fn onLogin(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.at_login = ev.on;
        cx.notify();
    }
    fn onDelay(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.delay = ev.value;
        cx.notify();
    }
    fn onDark(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.dark_style = ev.on;
        cx.notify();
    }
    fn onAccent(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.accent = ev.index;
        cx.notify();
    }
    fn onScale(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.text_scale = ev.value;
        cx.notify();
    }
    fn onDensity(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.density = ev.index;
        cx.notify();
    }
    fn onPosition(self: *Prefs, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Prefs)) void {
        self.position = ev.index;
        cx.notify();
    }
    fn onApps(self: *Prefs, ev: *const prefs.ListEvent, _: *Window, cx: *Context(Prefs)) void {
        switch (ev.*) {
            .select => |i| self.selected = i,
            .add => for (&self.apps) |*on| if (!on.*) {
                on.* = true;
                break;
            },
            .remove => |i| {
                var n: u32 = 0;
                for (&self.apps) |*on| if (on.*) {
                    if (n == i) {
                        on.* = false;
                        break;
                    }
                    n += 1;
                };
                self.selected = null;
            },
        }
        cx.notify();
    }
};

const Launch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    smoke_frames: ?u64 = null,
    out: []const u8 = "zig-out/prefs-demo.png",
    dark: ?bool = null,
    accent: ?u32 = null,
    open_popup: bool = false,
    exit_code: u8 = 0,
};

var launch_state: Launch = undefined;

fn initPrefs(window: *Window, _: *Context(Prefs)) Prefs {
    const l = &launch_state;
    // Draw libadwaita / Breeze controls where the platform has no native ones (Linux).
    window.setDesktopControls(true);
    if (l.dark != null or l.accent != null) {
        var t = window.desktopTheme();
        t.dark = l.dark;
        if (l.accent) |a| t.accent = a;
        window.setDesktopTheme(t);
    }
    // macOS: AppKit controls follow the app theme pin.
    if (l.dark) |d| window.glass_dark = d;
    return .{};
}

fn onLaunch(l: *Launch, app: *App) void {
    app.quit_when_last_window_closes = true;
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 680, .height = 1000 } },
        .titlebar = if (builtin.os.tag == .macos) .{ .title = "Preferences" } else null,
        .app_id = "dev.zpui.prefs-demo",
    }, Prefs, initPrefs, .{}) catch |err| {
        std.debug.print("FAIL: openWindow: {t}\n", .{err});
        l.exit_code = 1;
        app.quit();
        return;
    };
    const win = handle.window(app).?;
    if (l.open_popup) {
        // Click the accent drop-down once laid out (screenshots of the open list).
        win.onNextFrame(@as(u8, 3), struct {
            fn f(left: *const u8, w: *Window, _: *App) void {
                if (left.* > 0) return w.onNextFrame(left.* - 1, f);
                openPopup(w);
            }
        }.f);
    }
    if (l.smoke_frames) |n| {
        const Tick = struct {
            left: u64,
            fn tick(self: *const @This(), w: *Window, a: *App) void {
                if (self.left > 0) {
                    // Windows: also read back the last presented frame (zpui content only).
                    if (builtin.os.tag == .windows and self.left == 1) if (zpui.windows_platform.Window.fromWindow(w.platform_window).renderer) |*r| r.requestCapture();
                    w.refresh();
                    return w.onNextFrame(@This(){ .left = self.left - 1 }, tick);
                }
                if (builtin.os.tag == .windows) saveSurfaceCapture(w);
                capture(w) catch |err| {
                    std.debug.print("FAIL: prefs-demo capture: {t}\n", .{err});
                    launch_state.exit_code = 1;
                };
                a.quit();
            }
        };
        win.onNextFrame(Tick{ .left = n }, Tick.tick);
    }
}

/// Finds the accent combo box in the accessibility tree and clicks it.
fn openPopup(w: *Window) void {
    w.setA11yActive(true);
    w.refresh();
    w.onNextFrame(@as(u8, 0), struct {
        fn f(_: *const u8, win: *Window, _: *App) void {
            const tree = win.a11yTree();
            for (tree.nodes.items) |n| {
                if (n.role != .combo_box) continue;
                const b = n.bounds;
                const p: zpui.Point(f32) = .{ .x = b.origin.x + b.size.width / 2, .y = b.origin.y + b.size.height / 2 };
                _ = win.dispatchEvent(.{ .mouse_move = .{ .position = p } });
                _ = win.dispatchEvent(.{ .mouse_down = .{ .button = .left, .position = p, .click_count = 1 } });
                _ = win.dispatchEvent(.{ .mouse_up = .{ .button = .left, .position = p, .click_count = 1 } });
                return;
            }
        }
    }.f);
}

/// Windows: the swapchain frame read back by the renderer, next to the screen capture.
fn saveSurfaceCapture(w: *Window) void {
    if (builtin.os.tag != .windows) return;
    const l = &launch_state;
    const r = &(zpui.windows_platform.Window.fromWindow(w.platform_window).renderer orelse return);
    const cap = r.takeCapture() orelse return;
    defer l.gpa.free(cap.rgba);
    var i: usize = 0;
    while (i + 4 <= cap.rgba.len) : (i += 4) {
        const a: u32 = cap.rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (cap.rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
    const encoded = png.encode(l.gpa, cap.width, cap.height, cap.rgba) catch return;
    defer l.gpa.free(encoded);
    std.Io.Dir.cwd().createDirPath(l.io, "zig-out") catch {};
    std.Io.Dir.cwd().writeFile(l.io, .{ .sub_path = "zig-out/prefs-demo-surface.png", .data = encoded }) catch return;
    std.debug.print("prefs-demo: wrote zig-out/prefs-demo-surface.png ({d}x{d})\n", .{ cap.width, cap.height });
}

fn capture(w: *Window) !void {
    const l = &launch_state;
    const img = switch (builtin.os.tag) {
        .linux => try captureX11(l.gpa, l.io, w.platform_window),
        .macos => try captureMac(l.gpa, w.platform_window),
        .windows => try captureWindows(l.gpa, w.platform_window),
        else => return error.CaptureUnsupported,
    };
    defer l.gpa.free(img.pixels);
    const encoded = try png.encode(l.gpa, img.width, img.height, img.pixels);
    defer l.gpa.free(encoded);
    if (std.fs.path.dirname(l.out)) |dir| try std.Io.Dir.cwd().createDirPath(l.io, dir);
    try std.Io.Dir.cwd().writeFile(l.io, .{ .sub_path = l.out, .data = encoded });
    std.debug.print("prefs-demo: wrote {s} ({d}x{d})\n", .{ l.out, img.width, img.height });
}

/// The window's rectangle of the X11 root, through ImageMagick `import` (PPM).
fn captureX11(gpa: std.mem.Allocator, io: std.Io, pw: zpui.platform.Window) !png.Image {
    const b = pw.bounds();
    const scale = pw.scaleFactor();
    const content = pw.contentSize();
    var crop_buf: [64]u8 = undefined;
    const crop = try std.fmt.bufPrint(&crop_buf, "{d}x{d}+{d}+{d}", .{
        @as(u32, @intFromFloat(@round(content.width * scale))),
        @as(u32, @intFromFloat(@round(content.height * scale))),
        @max(@as(i32, @intFromFloat(@round(b.origin.x * scale))), 0),
        @max(@as(i32, @intFromFloat(@round(b.origin.y * scale))), 0),
    });
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "import", "-window", "root", "-crop", crop, "+repage", "-depth", "8", "ppm:-" },
        .stdout_limit = .limited(256 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.term.success()) {
        std.debug.print("prefs-demo: import failed: {s}\n", .{res.stderr});
        return error.ImportFailed;
    }
    return parsePpm(gpa, res.stdout);
}

fn parsePpm(gpa: std.mem.Allocator, bytes: []const u8) !png.Image {
    if (bytes.len < 2 or !std.mem.eql(u8, bytes[0..2], "P6")) return error.NotPpm;
    var pos: usize = 2;
    var fields: [3]u32 = undefined;
    for (&fields) |*f| {
        while (pos < bytes.len and (std.ascii.isWhitespace(bytes[pos]) or bytes[pos] == '#')) {
            if (bytes[pos] == '#') {
                while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
            } else pos += 1;
        }
        const s = pos;
        while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) pos += 1;
        f.* = try std.fmt.parseInt(u32, bytes[s..pos], 10);
    }
    pos += 1;
    const n = @as(usize, fields[0]) * fields[1];
    if (fields[2] != 255 or bytes.len < pos + n * 3) return error.BadPpm;
    const pixels = try gpa.alloc(u8, n * 4);
    for (0..n) |i| {
        pixels[i * 4 ..][0..3].* = bytes[pos + i * 3 ..][0..3].*;
        pixels[i * 4 + 3] = 255;
    }
    return .{ .width = fields[0], .height = fields[1], .pixels = pixels };
}

/// The window's client area as composited on screen (zpui content + the native child
/// controls), through a GDI blit of the screen.
fn captureWindows(gpa: std.mem.Allocator, pw: zpui.platform.Window) !png.Image {
    if (builtin.os.tag != .windows) unreachable;
    const w = zpui.windows_platform.win32;
    const hwnd = zpui.windows_platform.Window.fromWindow(pw).hwnd;
    var rc: w.RECT = .{};
    _ = w.GetClientRect(hwnd, &rc);
    var origin: w.POINT = .{};
    _ = w.ClientToScreen(hwnd, &origin);
    const width = rc.width();
    const height = rc.height();
    if (width <= 0 or height <= 0) return error.EmptyWindowImage;
    _ = w.DwmFlush();
    const screen = w.GetDC(null) orelse return error.NoDC;
    defer _ = w.ReleaseDC(null, screen);
    const mem = w.CreateCompatibleDC(screen) orelse return error.NoDC;
    defer _ = w.DeleteDC(mem);
    var bits: ?*anyopaque = null;
    const bmi: w.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = width, .biHeight = -height } };
    const bmp = w.CreateDIBSection(screen, &bmi, 0, &bits, null, 0) orelse return error.NoBitmap;
    defer _ = w.DeleteObject(bmp);
    const old = w.SelectObject(mem, bmp);
    defer _ = w.SelectObject(mem, old.?);
    if (w.BitBlt(mem, 0, 0, width, height, screen, origin.x, origin.y, w.SRCCOPY | w.CAPTUREBLT) == 0) return error.BitBltFailed;
    const n: usize = @intCast(width * height * 4);
    const src: [*]const u8 = @ptrCast(bits.?);
    const pixels = try gpa.alloc(u8, n);
    var i: usize = 0;
    while (i < n) : (i += 4) pixels[i..][0..4].* = .{ src[i + 2], src[i + 1], src[i], 255 };
    return .{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}

/// The window alone via `CGWindowListCreateImage` (straight RGBA8).
fn captureMac(gpa: std.mem.Allocator, pw: zpui.platform.Window) !png.Image {
    if (builtin.os.tag != .macos) unreachable;
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const number = mac.MacWindow.fromWindow(pw).windowNumber();
    const create_image = cf.cgWindowListCreateImage() orelse return error.CGWindowListCreateImageUnavailable;
    const image = create_image(cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, number, cf.kCGWindowImageBoundsIgnoreFraming | cf.kCGWindowImageBestResolution) orelse
        return error.CGWindowListCreateImageReturnedNull;
    defer cf.CGImageRelease(image);
    const w = cf.CGImageGetWidth(image);
    const h = cf.CGImageGetHeight(image);
    if (w == 0 or h == 0) return error.EmptyWindowImage;
    const pixels = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);
    const space = cf.CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, cf.kCGImageAlphaPremultipliedLast | cf.kCGBitmapByteOrder32Big) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    cf.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const a: u32 = pixels[i + 3];
        if (a == 0 or a == 255) continue;
        for (pixels[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env = init.environ_map;
    launch_state = .{ .gpa = gpa, .io = init.io };
    const l = &launch_state;
    if (env.get("ZPUI_SMOKE_FRAMES")) |v| l.smoke_frames = std.fmt.parseInt(u64, v, 10) catch 30;
    if (env.get("ZPUI_SMOKE_OUT")) |v| l.out = v;
    if (env.get("ZPUI_PREFS_APPEARANCE")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "dark")) l.dark = true else if (std.ascii.eqlIgnoreCase(v, "light")) l.dark = false;
    }
    if (env.get("ZPUI_PREFS_ACCENT")) |v| l.accent = std.fmt.parseInt(u32, std.mem.trimStart(u8, v, "#"), 16) catch null;
    if (env.get("ZPUI_PREFS_OPEN")) |v| l.open_popup = std.mem.eql(u8, v, "popup");

    const plat = switch (builtin.os.tag) {
        .linux => try zpui.linux_platform.create(gpa, .{ .io = init.io }),
        .macos => try zpui.mac_platform.create(gpa),
        .windows => try zpui.windows_platform.create(gpa, .{}),
        else => @compileError("prefs-demo runs on Linux, macOS and Windows"),
    };
    const app = try App.init(gpa, plat);
    app.run(l, onLaunch);
    app.deinit();
    if (l.exit_code != 0) std.process.exit(l.exit_code);
}
