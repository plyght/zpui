//! Desktop overlay demo (`zig build overlay-demo`; docs/DESKTOP_OVERLAY.md): a small
//! transparent always-on-top window pinned to the bottom-right corner of the work area,
//! with a rounded blob that pulses on every system-wide key / click (global input
//! monitor), a resize handle in its top-left corner (aspect-locked, anchor corner fixed;
//! drag the blob itself to move the overlay), click-through everywhere else (input
//! region), and a tray / menu bar item with Hide / Show and Quit.
//!
//! Draws only when something animates: after a pulse decays no frame is requested and
//! the process sleeps in the event loop.
//!
//! Smoke test (CI): `ZPUI_SMOKE_FRAMES=N zig build overlay-demo` renders N frames (a
//! pulse animation plus a burst of anchored resizes and a hide / show), then idles for
//! two seconds counting frames rendered while nothing animates (expected 0) and the
//! CPU time used, writes zig-out/overlay-demo.png (the overlay's scene through an
//! offscreen renderer, alpha kept) and exits; exit code 1 when frames never arrive or
//! frames are drawn while idle. `ZPUI_SMOKE_INPUT_WAIT_MS=ms` keeps it alive that much
//! longer before idling so a test can inject global key events (xdotool); the count
//! seen is printed.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const png = @import("png.zig");

const platform = zpui.platform;
const scene_mod = zpui.scene;
const color = zpui.color;
const desktop = platform.desktop;
const Renderer = zpui.renderer.Renderer;

const watchdog_ns = 60 * std.time.ns_per_s;
const idle_window_ns = 2 * std.time.ns_per_s;
const pulse_decay_per_s: f32 = 3.5;
const handle_size: f32 = 18;
const min_width: f32 = 64;
const max_width: f32 = 480;

const tag_toggle: usize = 1;
const tag_quit: usize = 2;

const Drag = enum { none, resize, move };

const Demo = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    plat: platform.Platform,
    window: ?platform.Window = null,
    scene: scene_mod.Scene = .{},
    anchor: platform.OverlayAnchor = .{ .corner = .bottom_right, .margin = .{ .x = 24, .y = 24 } },
    size: platform.Size = .{ .width = 160, .height = 160 },
    visible: bool = true,

    pulse: f32 = 0,
    paw_x: f32 = 0.5,
    last_frame_ns: u64 = 0,
    animating: bool = false,

    drag: Drag = .none,
    drag_start_mouse: platform.Point = .zero,
    drag_start_size: platform.Size = .{ .width = 0, .height = 0 },
    drag_start_margin: platform.Point = .zero,

    frames: u64 = 0,
    global_events: u64 = 0,
    // smoke
    smoke_frames: ?u64 = null,
    smoke_phase: enum { off, warmup, resizing, idle, done } = .off,
    resize_step: u32 = 0,
    idle_start_frames: u64 = 0,
    idle_start_cpu_ns: u64 = 0,
    input_wait_ns: u64 = 0,
    exit_code: u8 = 0,

    fn now(d: *Demo) u64 {
        return d.plat.dispatcher().now();
    }

    // -- scene ------------------------------------------------------------------------

    fn quad(s: f32, mask: scene_mod.ContentMask, x: f32, y: f32, w: f32, h: f32, r: f32, bg: color.Hsla) scene_mod.Quad {
        return .{
            .bounds = .{ .origin = .{ .x = x * s, .y = y * s }, .size = .{ .width = w * s, .height = h * s } },
            .content_mask = mask,
            .background = color.solidBackground(bg),
            .corner_radii = .all(r * s),
        };
    }

    fn hex(v: u32, a: f32) color.Hsla {
        var h = color.rgb(v).toHsla();
        h.a = a;
        return h;
    }

    /// The blob's rect (content coordinates): inset from the window, leaving the handle.
    fn blobRect(size: platform.Size) platform.Bounds {
        const inset = size.width * 0.14;
        return .{ .origin = .{ .x = inset, .y = inset }, .size = .{ .width = size.width - 2 * inset, .height = size.height - 2 * inset } };
    }

    fn handleRect() platform.Bounds {
        return .{ .origin = .zero, .size = .{ .width = handle_size, .height = handle_size } };
    }

    fn buildScene(d: *Demo, size: platform.Size, s: f32) !void {
        const gpa = d.gpa;
        const sc = &d.scene;
        sc.clear(gpa);
        const mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = size.width * s, .height = size.height * s } } };
        const b = blobRect(size);
        // The blob swells with the pulse and leans towards the paw that typed.
        const grow = d.pulse * size.width * 0.06;
        const lean = (d.paw_x - 0.5) * d.pulse * size.width * 0.08;
        const r = (b.size.width + 2 * grow) * 0.45;
        try sc.insertQuad(gpa, quad(s, mask, b.origin.x - grow + lean, b.origin.y - grow, b.size.width + 2 * grow, b.size.height + 2 * grow, r, hex(0x8b5cf6, 0.55 + 0.35 * d.pulse)));
        // Eyes.
        const eye = size.width * 0.07;
        const ey = b.origin.y + b.size.height * 0.38;
        try sc.insertQuad(gpa, quad(s, mask, b.origin.x + b.size.width * 0.3 - eye / 2 + lean, ey, eye, eye * (1 - 0.6 * d.pulse), eye / 2, hex(0xffffff, 0.95)));
        try sc.insertQuad(gpa, quad(s, mask, b.origin.x + b.size.width * 0.7 - eye / 2 + lean, ey, eye, eye * (1 - 0.6 * d.pulse), eye / 2, hex(0xffffff, 0.95)));
        // Resize handle (top-left: the corner opposite the bottom-right anchor).
        const h = handleRect();
        try sc.insertQuad(gpa, quad(s, mask, h.origin.x + 3, h.origin.y + 3, h.size.width - 6, h.size.height - 6, 4, hex(0xffffff, if (d.drag == .resize) 0.9 else 0.5)));
        sc.finish();
    }

    // -- window callbacks -------------------------------------------------------------

    fn onRequestFrame(ctx: ?*anyopaque, _: bool) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        const w = d.window orelse return;
        const t = d.now();
        const dt: f32 = if (d.last_frame_ns == 0) 0 else @as(f32, @floatFromInt(t -| d.last_frame_ns)) / std.time.ns_per_s;
        d.last_frame_ns = t;
        d.pulse = @max(0, d.pulse - dt * pulse_decay_per_s);
        d.buildScene(w.contentSize(), w.scaleFactor()) catch |e| std.debug.print("scene error: {t}\n", .{e});
        w.draw(&d.scene) catch |e| std.debug.print("draw error: {t}\n", .{e});
        d.frames += 1;
        d.animating = d.pulse > 0.001 or d.smoke_phase == .warmup;
        if (d.animating) w.requestFrame() else d.last_frame_ns = 0;
    }

    fn onInput(ctx: ?*anyopaque, ev: zpui.input.PlatformInput) platform.DispatchEventResult {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        const w = d.window orelse return .{};
        switch (ev) {
            .mouse_down => |m| {
                const screen = w.screenMousePosition() orelse return .{};
                d.drag_start_mouse = screen;
                d.drag_start_size = w.contentSize();
                d.drag_start_margin = d.anchor.margin;
                const h = handleRect();
                d.drag = if (m.position.x < h.size.width and m.position.y < h.size.height) .resize else .move;
                w.requestFrame();
            },
            .mouse_move => if (d.drag != .none) {
                const p = w.screenMousePosition() orelse return .{};
                const delta: platform.Point = .{ .x = p.x - d.drag_start_mouse.x, .y = p.y - d.drag_start_mouse.y };
                switch (d.drag) {
                    .resize => {
                        const size = desktop.aspectResize(d.anchor.corner, d.drag_start_size, delta, min_width, max_width);
                        if (size.width != d.size.width) d.setSize(size);
                    },
                    .move => {
                        // Bottom-right anchor: moving right / down shrinks the margins.
                        d.anchor.margin = .{ .x = @max(0, d.drag_start_margin.x - delta.x), .y = @max(0, d.drag_start_margin.y - delta.y) };
                        w.setAnchor(d.anchor, null);
                    },
                    .none => {},
                }
            },
            .mouse_up => {
                d.drag = .none;
                w.requestFrame();
            },
            else => {},
        }
        return .{};
    }

    fn setSize(d: *Demo, size: platform.Size) void {
        const w = d.window orelse return;
        d.size = size;
        w.vtable.resize(w.ptr, size);
        d.updateInputRegion(size);
    }

    fn updateInputRegion(d: *Demo, size: platform.Size) void {
        const w = d.window orelse return;
        // Only the blob and the handle take clicks; the transparent rest passes through.
        const rects = [_]platform.Bounds{ blobRect(size), handleRect() };
        w.setInputRegion(&rects);
    }

    fn onResize(ctx: ?*anyopaque, size: platform.Size, _: f32) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        if (d.window) |w| w.requestFrame();
        _ = size;
    }

    fn onClose(ctx: ?*anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        d.window = null;
        d.plat.quit();
    }

    // -- global input / tray ----------------------------------------------------------

    fn onGlobalInput(ctx: ?*anyopaque, e: platform.GlobalInputEvent) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        switch (e.kind) {
            .key_down, .mouse_down => {
                d.global_events += 1;
                d.pulse = 1;
                d.paw_x = e.key_x;
                if (d.window) |w| if (!d.animating) {
                    d.animating = true;
                    w.requestFrame();
                };
            },
            else => {},
        }
    }

    fn onMenuAction(ctx: ?*anyopaque, tag: usize) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        switch (tag) {
            tag_toggle => d.setVisible(!d.visible),
            tag_quit => d.plat.quit(),
            else => {},
        }
    }

    fn setVisible(d: *Demo, visible: bool) void {
        const w = d.window orelse return;
        d.visible = visible;
        w.setVisible(visible);
        if (visible) w.requestFrame();
    }

    fn installTray(d: *Demo) void {
        // A 32x32 filled circle (template image on macOS: alpha is what counts).
        var px: [32 * 32 * 4]u8 = undefined;
        for (0..32) |y| for (0..32) |x| {
            const dx = @as(f32, @floatFromInt(x)) - 15.5;
            const dy = @as(f32, @floatFromInt(y)) - 15.5;
            const a: u8 = if (dx * dx + dy * dy < 14 * 14) 255 else 0;
            px[(y * 32 + x) * 4 ..][0..4].* = .{ 0, 0, 0, a };
        };
        const icon = png.encode(d.gpa, 32, 32, &px) catch return;
        defer d.gpa.free(icon);
        const items = [_]platform.MenuItem{
            .{ .action = .{ .name = "Hide / Show", .tag = tag_toggle } },
            .separator,
            .{ .action = .{ .name = "Quit", .tag = tag_quit } },
        };
        d.plat.setTrayItem(.{ .icon_png = icon, .tooltip = "zpui overlay demo", .menu = &items }) catch |e|
            std.debug.print("tray: {t} (no tray host)\n", .{e});
    }

    // -- launch -----------------------------------------------------------------------

    fn onLaunch(ctx: ?*anyopaque, _: void) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        const w = d.plat.openWindow(.{
            .bounds = .{ .origin = .zero, .size = d.size },
            .titlebar = null,
            .kind = .overlay,
            .background = .transparent,
            .focus = false,
            .anchor = d.anchor,
            .app_id = "dev.zpui.overlay-demo",
        }) catch |e| {
            std.debug.print("FAIL: openWindow: {t}\n", .{e});
            d.exit_code = 1;
            d.plat.quit();
            return;
        };
        d.window = w;
        w.setCallbacks(.{ .ctx = d, .request_frame = onRequestFrame, .input = onInput, .resize = onResize, .close = onClose });
        d.updateInputRegion(d.size);
        d.installTray();

        const status = d.plat.startGlobalInputMonitor(.{ .ctx = d, .func = onGlobalInput });
        std.debug.print("global input monitor: {t} (permission: {t})\n", .{ status, d.plat.inputPermission() });
        var buf: [256]u8 = undefined;
        if (d.plat.foregroundApp(&buf)) |fg| std.debug.print("foreground app: {s} ({s})\n", .{ fg.id, fg.name }) else std.debug.print("foreground app: unknown\n", .{});

        if (d.smoke_frames != null) {
            d.smoke_phase = .warmup;
            d.pulse = 1;
            d.plat.dispatcher().dispatchAfter(watchdog_ns, .{ .ctx = d, .run = onWatchdog });
            d.plat.dispatcher().dispatchAfter(50 * std.time.ns_per_ms, .{ .ctx = d, .run = onSmokeTick });
        }
        w.requestFrame();
    }

    // -- smoke test -------------------------------------------------------------------

    fn onSmokeTick(ctx: *anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx));
        const disp = d.plat.dispatcher();
        switch (d.smoke_phase) {
            .warmup => if (d.frames >= d.smoke_frames.?) {
                std.debug.print("rendered {d} frames; resizing\n", .{d.frames});
                d.smoke_phase = .resizing;
            },
            .resizing => {
                // 60 anchored resizes, one per tick (grow then shrink back), then hide / show.
                if (d.resize_step < 60) {
                    const t: f32 = @floatFromInt(d.resize_step);
                    const wdt: f32 = 160 + 60 * @sin(t / 60 * std.math.pi);
                    d.setSize(.{ .width = @round(wdt), .height = @round(wdt) });
                    d.resize_step += 1;
                } else {
                    d.setSize(.{ .width = 160, .height = 160 });
                    d.setVisible(false);
                    d.setVisible(true);
                    d.pulse = 0;
                    d.smoke_phase = .idle;
                    disp.dispatchAfter(d.input_wait_ns + 500 * std.time.ns_per_ms, .{ .ctx = d, .run = onIdleStart });
                    return;
                }
                disp.dispatchAfter(16 * std.time.ns_per_ms, .{ .ctx = d, .run = onSmokeTick });
                return;
            },
            else => return,
        }
        disp.dispatchAfter(50 * std.time.ns_per_ms, .{ .ctx = d, .run = onSmokeTick });
    }

    fn onIdleStart(ctx: *anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx));
        std.debug.print("global input events seen: {d}; {d} frames so far (warmup, resizes, hide / show)\n", .{ d.global_events, d.frames });
        // Let a pulse from injected input finish, then measure.
        d.idle_start_frames = d.frames;
        d.idle_start_cpu_ns = cpuTimeNs();
        d.plat.dispatcher().dispatchAfter(idle_window_ns, .{ .ctx = d, .run = onIdleEnd });
    }

    fn onIdleEnd(ctx: *anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx));
        const idle_frames = d.frames - d.idle_start_frames;
        const cpu_ms = (cpuTimeNs() -| d.idle_start_cpu_ns) / std.time.ns_per_ms;
        std.debug.print("idle: {d} frames rendered, {d} ms CPU in {d} s (global input monitor running)\n", .{ idle_frames, cpu_ms, idle_window_ns / std.time.ns_per_s });
        if (idle_frames > 0) {
            std.debug.print("FAIL: frames rendered while nothing animates\n", .{});
            d.exit_code = 1;
        }
        d.capture() catch |e| {
            std.debug.print("FAIL: capture: {t}\n", .{e});
            d.exit_code = 1;
        };
        d.smoke_phase = .done;
        d.plat.quit();
    }

    fn onWatchdog(ctx: *anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx));
        if (d.smoke_phase == .done) return;
        std.debug.print("FAIL: smoke test stuck in {t} after {d} frames\n", .{ d.smoke_phase, d.frames });
        d.exit_code = 1;
        d.smoke_phase = .done;
        d.plat.quit();
    }

    /// The overlay's scene (mid-pulse) through an offscreen renderer: transparent
    /// background kept, so the PNG shows exactly what composites over the desktop.
    fn capture(d: *Demo) !void {
        const w = d.window orelse return error.NoWindow;
        const scale = w.scaleFactor();
        const content = w.contentSize();
        const size: zpui.Size(zpui.DevicePixels) = .{ .width = @intFromFloat(@round(content.width * scale)), .height = @intFromFloat(@round(content.height * scale)) };
        var r = try Renderer.init(d.gpa, .{ .size = size, .transparent = true });
        defer r.deinit();
        d.pulse = 0.6;
        d.paw_x = 0.3;
        try d.buildScene(content, scale);
        try r.drawScene(&d.scene, size, scale, color.transparent_black);
        const pixels = try r.readPixels(d.gpa);
        defer d.gpa.free(pixels);
        unpremultiply(pixels);
        const pw: usize = @intCast(size.width);
        const corner = pixels[(2 * pw + pw - 3) * 4 ..][0..4];
        const centre = pixels[((@as(usize, @intCast(size.height)) / 2) * pw + pw / 2) * 4 ..][0..4];
        std.debug.print("pixel corner rgba({d},{d},{d},{d}) centre rgba({d},{d},{d},{d})\n", .{ corner[0], corner[1], corner[2], corner[3], centre[0], centre[1], centre[2], centre[3] });
        std.Io.Dir.cwd().createDirPath(d.io, "zig-out") catch {};
        const encoded = try png.encode(d.gpa, @intCast(size.width), @intCast(size.height), pixels);
        defer d.gpa.free(encoded);
        try std.Io.Dir.cwd().writeFile(d.io, .{ .sub_path = "zig-out/overlay-demo.png", .data = encoded });
        std.debug.print("wrote zig-out/overlay-demo.png ({d}x{d})\n", .{ size.width, size.height });
        if (corner[3] != 0) return error.CornerNotTransparent;
        if (centre[3] < 150) return error.BlobMissing;
    }
};

fn cpuTimeNs() u64 {
    var ru: std.posix.rusage = undefined;
    ru = std.posix.getrusage(std.posix.rusage.SELF);
    const tv = struct {
        fn ns(t: std.posix.timeval) u64 {
            return @as(u64, @intCast(t.sec)) * std.time.ns_per_s + @as(u64, @intCast(t.usec)) * std.time.ns_per_us;
        }
    };
    return tv.ns(ru.utime) + tv.ns(ru.stime);
}

fn unpremultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}

fn createPlatform(gpa: std.mem.Allocator, io: std.Io) !platform.Platform {
    return switch (builtin.os.tag) {
        .macos => zpui.mac_platform.create(gpa),
        .linux => zpui.linux_platform.create(gpa, .{ .io = io }),
        else => error.Unsupported,
    };
}

pub fn main(init: std.process.Init) !void {
    // c_allocator: windows are still open when `run` returns (process exit cleans up).
    const gpa = std.heap.c_allocator;
    const smoke: ?u64 = if (init.environ_map.get("ZPUI_SMOKE_FRAMES")) |v| std.fmt.parseInt(u64, v, 10) catch 30 else null;
    const wait_ms: u64 = if (init.environ_map.get("ZPUI_SMOKE_INPUT_WAIT_MS")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;

    const plat = try createPlatform(gpa, init.io);
    defer plat.deinit();
    var demo: Demo = .{ .gpa = gpa, .io = init.io, .plat = plat, .smoke_frames = smoke, .input_wait_ns = wait_ms * std.time.ns_per_ms };
    defer demo.scene.deinit(gpa);
    plat.vtable.setCallbacks(plat.ptr, .{ .ctx = &demo, .menu_action = Demo.onMenuAction });
    std.debug.print("zpui overlay-demo: smoke={?d}\n", .{smoke});
    plat.run(.{ .ctx = &demo, .func = Demo.onLaunch });
    std.debug.print("run loop exited after {d} frames (exit code {d})\n", .{ demo.frames, demo.exit_code });
    if (demo.exit_code != 0) std.process.exit(demo.exit_code);
}
