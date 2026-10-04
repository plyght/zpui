//! [glass-lab] Liquid Glass lab (`ZERON_GLASS_LAB=1 zeron [--light|--dark] [--smoke-frames N]`,
//! or `zig build glass-lab`): evidence for "why does native glass look flat in CI".
//!
//! The window is filled with high-contrast content on the main Metal surface (gradient,
//! diagonal stripes, colored blocks, large text) and, in the bottom band, content that
//! moves every frame. Native `NSGlassEffectView`s sit over both: regular / clear,
//! rounded / capsule, tinted, and a merged `liquidGlassGroup`. Labels are each glass's
//! foreground (overlay plane). On macOS three reference views bypass zpui's hosting
//! (glass_debug.addControls): an `NSGlassEffectView` added straight to the content view,
//! a within-window `NSVisualEffectView`, and an AppKit-only scene (CALayer stripes under
//! an `NSGlassEffectView`).
//!
//! With `--smoke-frames N` it runs N frames, then (macOS):
//!   * prints `glass_debug.dump` (accessibility flags, window / layer flags, every glass
//!     view's properties and private layer tree) to stderr;
//!   * reads back what zpui's Metal planes presented (`<prefix>-metal-{main,overlay,top}.png`);
//!   * captures the window alone (`CGWindowListCreateImage`, `<prefix>-window.png`), what
//!     the display shows in the window's rect (`<prefix>-onscreen.png`), the whole display
//!     in-process (`<prefix>-display.png`) and with `screencapture -x` (`<prefix>-screencapture.png`);
//!   * prints per-panel statistics: luminance spread inside each glass (flat glass has
//!     ~0 spread over striped content) and the mean difference from the Metal readback
//!     (0 = the glass changed nothing, i.e. not rendered at all).
//! then exits 0 (1 only when frames or the window capture fail).
//!
//! Env: `ZERON_GLASS_LAB_BG=opaque|blurred|transparent` (window background; default
//! opaque), `ZERON_GLASS_LAB_OUT=<dir>` (default zig-out/glass-lab).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const smoke = @import("smoke.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const color = zpui.color;
const is_mac = builtin.os.tag == .macos;

pub const Background = enum { @"opaque", blurred, transparent };

pub const Options = struct {
    dark: bool = false,
    background: Background = .@"opaque",
    /// Capture after this many frames (null: interactive, no capture).
    frames: ?u64 = null,
    out_dir: []const u8 = "zig-out/glass-lab",
    timeout_s: i64 = 120,
};

pub const window_size: zpui.Size(f32) = .{ .width = 1200, .height = 820 };

fn hex(v: u32) zpui.Hsla {
    return zpui.rgb(v).toHsla();
}

// ---- layout (logical px, top-left origin of the content view) ------------------------

const Panel = struct {
    name: []const u8,
    label: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    style: zpui.LiquidGlassStyle = .regular,
    capsule: bool = false,
    radius: f32 = 24,
    tint: ?u32 = null,
};

const panels = [_]Panel{
    .{ .name = "p-regular", .label = "regular · rounded 28", .x = 40, .y = 70, .w = 260, .h = 190, .radius = 28 },
    .{ .name = "p-clear", .label = "clear · rounded 28", .x = 330, .y = 70, .w = 260, .h = 190, .style = .clear, .radius = 28 },
    .{ .name = "p-capsule", .label = "regular · capsule", .x = 620, .y = 70, .w = 250, .h = 84, .capsule = true },
    .{ .name = "p-capsule-clear", .label = "clear · capsule", .x = 620, .y = 176, .w = 250, .h = 84, .style = .clear, .capsule = true },
    .{ .name = "p-tinted", .label = "regular · tint orange", .x = 900, .y = 70, .w = 260, .h = 190, .radius = 20, .tint = 0xff8a00 },
    // Over the moving band.
    .{ .name = "p-motion", .label = "regular over motion", .x = 60, .y = 560, .w = 420, .h = 200, .radius = 28 },
    .{ .name = "p-motion-clear", .label = "clear capsule over motion", .x = 540, .y = 600, .w = 380, .h = 100, .style = .clear, .capsule = true },
    .{ .name = "p-motion-circle", .label = "circle", .x = 980, .y = 580, .w = 140, .h = 140, .capsule = true },
};

/// The merged group: three capsules 12 px apart, spacing 24 (they should fuse).
const group_rect = .{ .x = 40, .y = 310, .w = 520, .h = 90 };
const group_member_w: f32 = 160;
const group_gap: f32 = 12;

const Control = struct { label: []const u8, x: f32, y: f32, w: f32, h: f32 };
const control_direct: Control = .{ .label = "direct NSGlassEffectView", .x = 600, .y = 300, .w = 170, .h = 170 };
const control_vev: Control = .{ .label = "NSVisualEffectView in-window", .x = 790, .y = 300, .w = 170, .h = 170 };
const control_appkit: Control = .{ .label = "AppKit stripes + glass", .x = 980, .y = 300, .w = 180, .h = 170 };

const band_top: f32 = 500;

// ---- view ------------------------------------------------------------------------------

pub const Lab = struct {
    frame: u64 = 0,
    dark: bool,

    pub fn init(dark: bool, _: *Window, _: *Context(Lab)) Lab {
        return .{ .dark = dark };
    }

    pub fn render(self: *Lab, window: *Window, _: *Context(Lab)) zpui.Div {
        self.frame += 1;
        window.glass_dark = self.dark;
        window.requestAnimationFrame(); // the band moves every frame
        const fg = if (self.dark) zpui.color.white else hex(0x111111);

        var root = div().relative().sizeFull().overflowHidden().fontFamily("Geist")
            .bg(color.linearGradient(135, color.linearColorStop(hex(0xff2d95), 0), color.linearColorStop(hex(0x1e6bff), 1)))
            .child(div().absolute().inset0().bg(color.patternSlash(hex(0x000000).opacity(0.55), 10, 28)));

        // Saturated blocks straddling glass edges.
        const blocks = [_]struct { x: f32, y: f32, s: f32, c: u32 }{
            .{ .x = 250, .y = 40, .s = 110, .c = 0xffe600 },   .{ .x = 560, .y = 200, .s = 100, .c = 0x00e676 },
            .{ .x = 840, .y = 30, .s = 120, .c = 0x00e5ff },   .{ .x = 10, .y = 240, .s = 90, .c = 0xffffff },
            .{ .x = 1100, .y = 220, .s = 100, .c = 0x111111 }, .{ .x = 470, .y = 360, .s = 90, .c = 0xffe600 },
        };
        for (blocks) |bl| root = root.child(div().absolute().left(px(bl.x)).top(px(bl.y)).w(px(bl.s)).h(px(bl.s)).rounded(px(18)).bg(hex(bl.c)));

        // Large text rows across the panels.
        root = root
            .child(div().absolute().left(px(20)).top(px(90)).whitespaceNowrap().textSize(px(118)).fontWeight(800).lineHeight(px(130))
                .textColor(zpui.color.white).child("LIQUID GLASS LAB"))
            .child(div().absolute().left(px(20)).top(px(300)).whitespaceNowrap().textSize(px(84)).fontWeight(800).lineHeight(px(96))
            .textColor(hex(0x111111)).child("Aa Bb 0123 \u{25CF}\u{25B2}\u{25A0}"));

        root = root.child(motionBand(self.frame));

        // Control captions (main surface, outside the control rects).
        for ([_]Control{ control_direct, control_vev, control_appkit }) |c|
            root = root.child(div().absolute().left(px(c.x)).top(px(c.y + c.h + 4)).w(px(c.w)).px(px(6)).py(px(2))
                .rounded(px(6)).bg(hex(0x000000).opacity(0.7)).textColor(zpui.color.white).textSize(px(11)).child(c.label));

        inline for (panels) |p| root = root.child(panel(p, fg));
        root = root.child(groupEl(fg));
        return root;
    }
};

fn motionBand(frame: u64) zpui.Div {
    const colors = [_]u32{ 0xff1744, 0xffea00, 0x00e676, 0x2979ff, 0xffffff, 0x000000 };
    const bar: f32 = 26;
    const period: f32 = bar * @as(f32, @floatFromInt(colors.len));
    const shift: f32 = @mod(@as(f32, @floatFromInt(frame)) * 3, period);
    var band = div().absolute().left(px(0)).right(px(0)).top(px(band_top)).h(px(window_size.height - band_top)).overflowHidden().bg(hex(0x202020));
    var x: f32 = -shift;
    var i: usize = 0;
    while (x < window_size.width) : ({
        x += bar;
        i += 1;
    }) band = band.child(div().absolute().top(px(0)).bottom(px(0)).left(px(x)).w(px(bar)).bg(hex(colors[i % colors.len])));
    const text_x = window_size.width - @mod(@as(f32, @floatFromInt(frame)) * 5, window_size.width + 900);
    return band
        .child(div().absolute().left(px(text_x)).top(px(110)).whitespaceNowrap().textSize(px(72)).fontWeight(800).lineHeight(px(80))
        .textColor(hex(0x111111)).bg(zpui.color.white.opacity(0.85)).px(px(12)).child("SCROLLING \u{25B8} CONTENT 0123456789"));
}

fn glassOpts(p: Panel) zpui.liquid_glass.Options {
    return .{
        .style = p.style,
        .shape = if (p.capsule) .capsule else .{ .rounded = p.radius },
        .tint = if (p.tint) |t| hex(t).opacity(0.6) else null,
    };
}

fn caption(fg: zpui.Hsla, text: []const u8) zpui.Div {
    return div().px(px(14)).py(px(10)).textSize(px(13)).fontWeight(600).textColor(fg).child(text);
}

fn panel(comptime p: Panel, fg: zpui.Hsla) zpui.Div {
    return div().absolute().left(px(p.x)).top(px(p.y)).w(px(p.w)).h(px(p.h))
        .child(zpui.liquidGlass(p.name, glassOpts(p), div().sizeFull().child(caption(fg, p.label))));
}

fn groupEl(fg: zpui.Hsla) zpui.Div {
    const member = struct {
        fn el(comptime name: []const u8, f: zpui.Hsla) zpui.liquid_glass.LiquidGlass {
            return zpui.liquidGlass(name, .{ .shape = .capsule }, div().w(px(group_member_w)).h(px(group_rect.h)).flex().itemsCenter().justifyCenter()
                .textSize(px(13)).fontWeight(600).textColor(f).child(name));
        }
    }.el;
    return div().absolute().left(px(group_rect.x)).top(px(group_rect.y)).w(px(group_rect.w)).h(px(group_rect.h))
        .child(zpui.liquidGlassGroup("lab-group", .{ .spacing = 24 }, div().sizeFull().flex().flexRow().gap(px(group_gap))
        .child(member("group 1", fg)).child(member("group 2", fg)).child(member("group 3", fg))));
}

// ---- open + smoke ----------------------------------------------------------------------

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    done: std.atomic.Value(bool) = .init(false),
    exit_code: u8 = 0,
    prefix_buf: [96]u8 = undefined,
    prefix: []const u8 = "",
};

var state: ?State = null;
var frames_seen: std.atomic.Value(u64) = .init(0);

/// Open the lab window (and arm the capture when `opts.frames` is set).
pub fn open(gpa: std.mem.Allocator, io: std.Io, app: *App, opts: Options) void {
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 60, .y = 60 }, .size = window_size },
        .titlebar = .{ .title = "", .appears_transparent = true, .traffic_light_position = .{ .x = 14, .y = 14 } },
        .background = switch (opts.background) {
            .@"opaque" => .opaque_,
            .blurred => .blurred,
            .transparent => .transparent,
        },
        .app_id = "sh.zeron.GlassLab",
    }, Lab, Lab.init, .{opts.dark}) catch |err| {
        std.debug.print("FAIL: glass lab: openWindow: {t}\n", .{err});
        app.quit();
        return;
    };
    const win = handle.window(app) orelse return app.quit();
    state = .{ .gpa = gpa, .io = io, .opts = opts };
    const s = &state.?;
    s.prefix = std.fmt.bufPrint(&s.prefix_buf, "{s}/{t}-{s}", .{ opts.out_dir, opts.background, if (opts.dark) "dark" else "light" }) catch "zig-out/glass-lab/lab";
    std.debug.print("glass lab: background={t} appearance={s} native glass={}\n", .{ opts.background, if (opts.dark) "dark" else "light", zpui.platformSupportsLiquidGlass(app) });
    if (is_mac) {
        const a = zpui.mac_platform.glass_debug.accessibility();
        std.debug.print("glass lab: accessibility reduceTransparency={} increaseContrast={} (AppKit renders glass/materials solid under Reduce Transparency)\n", .{ a.reduce_transparency, a.increase_contrast });
    }
    win.onNextFrame(Tick{ .frame = 0 }, Tick.tick);
    if (opts.frames) |n| {
        if (std.Thread.spawn(.{}, watchdog, .{ io, opts.timeout_s, n })) |t| t.detach() else |_| {}
    }
}

pub fn exitCode() u8 {
    const s = &(state orelse return 1);
    if (s.opts.frames == null) return 0;
    if (!s.done.load(.acquire)) {
        std.debug.print("FAIL: glass lab: the app quit before the capture\n", .{});
        return 1;
    }
    return s.exit_code;
}

fn watchdog(io: std.Io, timeout_s: i64, frames: u64) void {
    io.sleep(.fromSeconds(timeout_s), .awake) catch return;
    if (state) |*s| if (s.done.load(.acquire)) return;
    std.debug.print("FAIL: glass lab: only {d}/{d} frames within {d}s\n", .{ frames_seen.load(.monotonic), frames, timeout_s });
    std.process.exit(1);
}

const controls_at_frame: u64 = 3;
const max_readback_wait: u64 = 20;

const Tick = struct {
    frame: u64,
    /// Frame at which the Metal readback was armed (0 = not yet).
    armed_at: u64 = 0,

    fn tick(self: *const Tick, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        const s = &state.?;
        var next = self.*;
        next.frame += 1;
        if (is_mac and self.frame == controls_at_frame) addControls(win, s.opts.dark);
        const n = s.opts.frames orelse {
            if (self.frame <= controls_at_frame) win.onNextFrame(next, tick);
            return;
        };
        if (self.frame < n) return win.onNextFrame(next, tick);
        if (!is_mac) return finish(s, win, app);
        const mac = zpui.mac_platform;
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        if (self.armed_at == 0) {
            mac.glass_debug.dump(mw, "glass lab");
            mw.renderer.armLayerCapture();
            next.armed_at = self.frame;
            win.refresh();
            return win.onNextFrame(next, tick);
        }
        const got_main = mw.renderer.layer_captures[0] != null;
        if (!got_main and self.frame - self.armed_at < max_readback_wait) {
            win.refresh();
            return win.onNextFrame(next, tick);
        }
        mw.renderer.disarmLayerCapture();
        finish(s, win, app);
    }
};

fn addControls(win: *Window, dark: bool) void {
    if (!is_mac) return;
    const mac = zpui.mac_platform;
    const R = mac.glass_debug.Rect;
    const r = struct {
        fn of(c: Control) R {
            return .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h };
        }
    }.of;
    mac.glass_debug.addControls(mac.MacWindow.fromWindow(win.platform_window), .{
        .direct_glass = r(control_direct),
        .within_window_vev = r(control_vev),
        .appkit_scene = r(control_appkit),
        .dark = dark,
    });
    std.debug.print("glass lab: added AppKit reference views (direct glass, in-window NSVisualEffectView, AppKit-only scene)\n", .{});
}

fn finish(s: *State, win: *Window, app: *App) void {
    s.exit_code = if (captureAll(s, win)) 0 else |err| blk: {
        std.debug.print("FAIL: glass lab: {t}\n", .{err});
        break :blk 1;
    };
    s.done.store(true, .release);
    app.quit();
}

fn writePng(s: *State, suffix: []const u8, img: smoke.Image) !void {
    var buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}-{s}.png", .{ s.prefix, suffix });
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
    const encoded = try smoke.encodePng(s.gpa, img.width, img.height, img.pixels);
    defer s.gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = encoded });
    std.debug.print("glass lab: wrote {s} ({d}x{d})\n", .{ path, img.width, img.height });
}

fn captureAll(s: *State, win: *Window) !void {
    const gpa = s.gpa;
    if (!is_mac) {
        if (builtin.os.tag != .linux) return error.CaptureUnsupportedOnThisOs;
        const img = try smoke.captureX11(gpa, s.io, win.platform_window);
        defer gpa.free(img.pixels);
        return writePng(s, "window", img);
    }
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const mw = mac.MacWindow.fromWindow(win.platform_window);
    const scale = mw.scaleFactor();

    // (iii) What zpui's Metal planes presented (premultiplied → straight alpha).
    var metal_main: ?smoke.Image = null;
    defer if (metal_main) |m| gpa.free(m.pixels);
    inline for (.{ .{ .main, "metal-main" }, .{ .overlay, "metal-overlay" }, .{ .top, "metal-top" } }) |pl| {
        if (mw.renderer.takeLayerCapture(pl[0])) |cap| {
            smoke.unpremultiply(cap.rgba);
            const img: smoke.Image = .{ .width = cap.width, .height = cap.height, .pixels = cap.rgba };
            writePng(s, pl[1], img) catch |err| std.debug.print("glass lab: {s}: {t}\n", .{ pl[1], err });
            if (pl[0] == .main) metal_main = img else gpa.free(cap.rgba);
        } else std.debug.print("glass lab: no {s} readback (plane not drawn while armed)\n", .{pl[1]});
    }

    // (i) The window alone, as the smoke test captures it.
    const number = mw.windowNumber();
    const window_img = try smoke.captureMacImage(gpa, cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, number, cf.kCGWindowImageBoundsIgnoreFraming | cf.kCGWindowImageBestResolution);
    defer gpa.free(window_img.pixels);
    try writePng(s, "window", window_img);

    // (iv) What the display shows in the window's rect (all windows composited).
    const rect = mac.glass_debug.windowRectCG(mw);
    const onscreen: ?smoke.Image = smoke.captureMacImage(gpa, rect, cf.kCGWindowListOptionOnScreenOnly, cf.kCGNullWindowID, cf.kCGWindowImageBestResolution) catch |err| blk: {
        std.debug.print("glass lab: on-screen rect capture: {t}\n", .{err});
        break :blk null;
    };
    defer if (onscreen) |o| gpa.free(o.pixels);
    if (onscreen) |o| writePng(s, "onscreen", o) catch {};

    // The whole display, in-process and with screencapture(1).
    if (smoke.captureMacImage(gpa, cf.CGRectInfinite, cf.kCGWindowListOptionOnScreenOnly, cf.kCGNullWindowID, cf.kCGWindowImageDefault)) |d| {
        defer gpa.free(d.pixels);
        writePng(s, "display", d) catch {};
    } else |err| std.debug.print("glass lab: display capture: {t}\n", .{err});
    screencapture(s);

    // Per-panel numbers.
    std.debug.print("glass lab: per-panel stats (interior, lower half; luma stddev 0..255; diff = mean |capture - metal| per channel)\n", .{});
    std.debug.print("glass lab: {s:<18} {s:>11} {s:>11} {s:>11} {s:>10} {s:>10}\n", .{ "panel", "metal sd", "window sd", "onscreen sd", "win diff", "scr diff" });
    const Probe = struct { name: []const u8, x: f32, y: f32, w: f32, h: f32 };
    var probes: [panels.len + 4]Probe = undefined;
    for (panels, 0..) |p, i| probes[i] = .{ .name = p.name, .x = p.x, .y = p.y, .w = p.w, .h = p.h };
    probes[panels.len] = .{ .name = "group 1", .x = group_rect.x, .y = group_rect.y, .w = group_member_w, .h = group_rect.h };
    probes[panels.len + 1] = .{ .name = "ctl direct glass", .x = control_direct.x, .y = control_direct.y, .w = control_direct.w, .h = control_direct.h };
    probes[panels.len + 2] = .{ .name = "ctl in-window VEV", .x = control_vev.x, .y = control_vev.y, .w = control_vev.w, .h = control_vev.h };
    probes[panels.len + 3] = .{ .name = "ctl appkit glass", .x = control_appkit.x + 18, .y = control_appkit.y + 18, .w = control_appkit.w - 36, .h = control_appkit.h - 36 };
    for (probes) |p| {
        const r: Region = .{ .x = p.x + 14, .y = p.y + p.h * 0.55, .w = p.w - 28, .h = p.h * 0.45 - 10 };
        const ms = if (metal_main) |m| regionStats(m, r, scale) else RegionStats{};
        const ws = regionStats(window_img, r, scale);
        const os = if (onscreen) |o| regionStats(o, r, scale) else RegionStats{};
        const wd = if (metal_main) |m| regionDiff(window_img, m, r, scale) else -1;
        const od = if (onscreen) |o| (if (metal_main) |m| regionDiff(o, m, r, scale) else -1) else -1;
        std.debug.print("glass lab: {s:<18} {d:>11.1} {d:>11.1} {d:>11.1} {d:>10.1} {d:>10.1}   mean rgb window=({d:.0},{d:.0},{d:.0})\n", .{
            p.name, ms.sd, ws.sd, os.sd, wd, od, ws.mean[0], ws.mean[1], ws.mean[2],
        });
    }
    std.debug.print(
        \\glass lab: reading the table: metal sd is high everywhere (stripes). Real glass blurs/refracts:
        \\  window sd well below metal sd but > ~3, and diff > 0. Flat panel: sd ~0-3 with diff large.
        \\  Glass not rendered at all: sd ~ metal sd and diff ~0. Compare zpui panels with the ctl rows.
        \\
    , .{});

    const st = smoke.stats(window_img.pixels);
    if (st.differing < 0.01 or st.distinct < 8) return error.BlankFrame;
}

fn screencapture(s: *State) void {
    var buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}-screencapture.png", .{s.prefix}) catch return;
    const res = std.process.run(s.gpa, s.io, .{
        .argv = &.{ "screencapture", "-x", "-t", "png", path },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("glass lab: screencapture: {t}\n", .{err});
        return;
    };
    defer s.gpa.free(res.stdout);
    defer s.gpa.free(res.stderr);
    if (res.term.success()) std.debug.print("glass lab: wrote {s} (screencapture -x)\n", .{path}) else std.debug.print("glass lab: screencapture failed: {s}\n", .{res.stderr});
}

const Region = struct { x: f32, y: f32, w: f32, h: f32 };
const RegionStats = struct { sd: f64 = -1, mean: [3]f64 = .{ 0, 0, 0 } };

fn pixelRange(img: smoke.Image, r: Region, scale: f32) struct { x0: usize, y0: usize, x1: usize, y1: usize } {
    // Images may be larger than the content (window frame) or at another scale: map by
    // the image's own scale relative to the logical window size.
    const sx = @as(f32, @floatFromInt(img.width)) / window_size.width;
    const sy = @as(f32, @floatFromInt(img.height)) / window_size.height;
    _ = scale;
    const cx = struct {
        fn c(v: f32, max: u32) usize {
            return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(max))));
        }
    }.c;
    return .{ .x0 = cx(r.x * sx, img.width), .y0 = cx(r.y * sy, img.height), .x1 = cx((r.x + r.w) * sx, img.width), .y1 = cx((r.y + r.h) * sy, img.height) };
}

fn regionStats(img: smoke.Image, r: Region, scale: f32) RegionStats {
    const pr = pixelRange(img, r, scale);
    var n: f64 = 0;
    var sum: f64 = 0;
    var sum2: f64 = 0;
    var rgb: [3]f64 = .{ 0, 0, 0 };
    var y = pr.y0;
    while (y < pr.y1) : (y += 1) {
        var x = pr.x0;
        while (x < pr.x1) : (x += 1) {
            const p = img.pixels[(y * img.width + x) * 4 ..][0..4];
            const l = 0.2126 * @as(f64, @floatFromInt(p[0])) + 0.7152 * @as(f64, @floatFromInt(p[1])) + 0.0722 * @as(f64, @floatFromInt(p[2]));
            sum += l;
            sum2 += l * l;
            for (0..3) |c| rgb[c] += @floatFromInt(p[c]);
            n += 1;
        }
    }
    if (n == 0) return .{};
    const mean = sum / n;
    return .{ .sd = @sqrt(@max(sum2 / n - mean * mean, 0)), .mean = .{ rgb[0] / n, rgb[1] / n, rgb[2] / n } };
}

/// Mean per-channel |a - b| over the region (images mapped by their own scale).
fn regionDiff(a: smoke.Image, b: smoke.Image, r: Region, scale: f32) f64 {
    const pa = pixelRange(a, r, scale);
    const pb = pixelRange(b, r, scale);
    const w = @min(pa.x1 - pa.x0, pb.x1 - pb.x0);
    const h = @min(pa.y1 - pa.y0, pb.y1 - pb.y0);
    if (w == 0 or h == 0) return -1;
    var total: f64 = 0;
    for (0..h) |dy| for (0..w) |dx| {
        // Nearest sample in b when the scales differ.
        const bx = pb.x0 + dx * (pb.x1 - pb.x0) / (pa.x1 - pa.x0);
        const by = pb.y0 + dy * (pb.y1 - pb.y0) / (pa.y1 - pa.y0);
        const p = a.pixels[((pa.y0 + dy) * a.width + pa.x0 + dx) * 4 ..][0..3];
        const q = b.pixels[(by * b.width + bx) * 4 ..][0..3];
        for (p, q) |u, v| total += @floatFromInt(@abs(@as(i16, u) - @as(i16, v)));
    };
    return total / @as(f64, @floatFromInt(w * h * 3));
}
