//! macOS platform demo: `zig build mac-window`.
//!
//! Opens a blurred, transparent-titlebar window with a few rounded quads and
//! one that follows the mouse, and prints key / IME-relevant events.
//!
//! Smoke test (CI): `ZPUI_SMOKE_FRAMES=30 zig build mac-window` renders 30
//! display-link frames, then writes
//!   zig-out/mac-window-offscreen.png  (same scene through an offscreen Metal renderer)
//!   zig-out/mac-window.png            (the on-screen window via CGWindowListCreateImage; best effort)
//! and exits 0, or exits 1 with a diagnostic if frames never arrive within the
//! watchdog timeout or the offscreen image is blank.

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");

const mac = zpui.mac_platform;
const platform = zpui.platform;
const color = zpui.color;
const Scene = zpui.Scene;
const Renderer = zpui.renderer.Renderer;

const watchdog_ns = 30 * std.time.ns_per_s;
/// If the display link has produced nothing by then, drive frames with timers (and say so).
const fallback_after_ns = 3 * std.time.ns_per_s;

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    platform: platform.Platform,
    window: ?platform.Window = null,
    scene: Scene = .{},
    mouse: zpui.Point(f32) = .{ .x = 400, .y = 300 },
    frames: u64 = 0,
    smoke_frames: ?u64 = null,
    smoke_done: bool = false,
    using_fallback_timer: bool = false,
    exit_code: u8 = 0,
};

var app: App = undefined;

pub fn main(init: std.process.Init) !void {
    // c_allocator: the window is still open when `run` returns (process exit cleans up),
    // which the debug allocator would report as leaks.
    const gpa = std.heap.c_allocator;
    const smoke: ?u64 = if (init.environ_map.get("ZPUI_SMOKE_FRAMES")) |v| std.fmt.parseInt(u64, v, 10) catch 30 else null;

    app = .{ .gpa = gpa, .io = init.io, .platform = try mac.create(gpa), .smoke_frames = smoke };
    defer app.platform.deinit();
    defer app.scene.deinit(gpa);

    app.platform.vtable.setCallbacks(app.platform.ptr, .{ .quit = onQuit });
    std.debug.print("zpui mac-window: smoke={?d}\n", .{smoke});
    app.platform.run(.{ .func = onLaunch });
    std.debug.print("run loop exited after {d} frames (exit code {d})\n", .{ app.frames, app.exit_code });
    if (app.exit_code != 0) std.process.exit(app.exit_code);
}

fn onQuit(_: ?*anyopaque) void {
    std.debug.print("quit requested\n", .{});
}

fn onLaunch(_: ?*anyopaque, _: void) void {
    const p = app.platform;
    var displays: [8]platform.Display = undefined;
    const n = p.vtable.displays(p.ptr, &displays);
    for (displays[0..n]) |d| std.debug.print("display {d}: {d}x{d} @{d}x visible {d}x{d}\n", .{
        d.id, d.bounds.size.width, d.bounds.size.height, d.scale_factor, d.visible_bounds.size.width, d.visible_bounds.size.height,
    });
    std.debug.print("appearance={s} reduced_motion={}\n", .{ @tagName(p.vtable.windowAppearance(p.ptr)), p.vtable.prefersReducedMotion(p.ptr) });

    const window = p.openWindow(.{
        .bounds = .{ .origin = .{ .x = 120, .y = 120 }, .size = .{ .width = 800, .height = 600 } },
        .titlebar = .{ .title = "zpui mac-window", .appears_transparent = true, .traffic_light_position = .{ .x = 14, .y = 14 } },
        .min_size = .{ .width = 320, .height = 240 },
        .background = .blurred,
    }) catch |err| {
        std.debug.print("FAIL: openWindow: {s}\n", .{@errorName(err)});
        app.exit_code = 1;
        p.quit();
        return;
    };
    app.window = window;
    window.setCallbacks(.{
        .request_frame = onRequestFrame,
        .input = onInput,
        .resize = onResize,
        .active_status_change = onActive,
        .close = onClose,
        .appearance_changed = onAppearance,
    });
    p.vtable.activate(p.ptr, true);
    window.requestFrame();
    std.debug.print("window open: content {d}x{d} @{d}x\n", .{ window.contentSize().width, window.contentSize().height, window.scaleFactor() });

    if (app.smoke_frames != null) {
        const d = p.dispatcher();
        d.dispatchAfter(watchdog_ns, .{ .ctx = &app, .run = onWatchdog });
        d.dispatchAfter(fallback_after_ns, .{ .ctx = &app, .run = onFallbackCheck });
    }
}

fn onRequestFrame(_: ?*anyopaque, force: bool) void {
    _ = force;
    const window = app.window orelse return;
    buildScene(window.contentSize(), window.scaleFactor()) catch |err| {
        std.debug.print("scene error: {s}\n", .{@errorName(err)});
        return;
    };
    window.draw(&app.scene) catch |err| {
        std.debug.print("draw error: {s}\n", .{@errorName(err)});
        return;
    };
    app.frames += 1;
    if (app.smoke_frames) |target| {
        if (app.frames >= target and !app.smoke_done) {
            app.smoke_done = true;
            finishSmoke(window);
            return;
        }
        window.requestFrame(); // keep the display link busy until we have enough frames
    }
}

fn buildScene(content: platform.Size, scale: f32) !void {
    const gpa = app.gpa;
    app.scene.clear(gpa);
    const s = scale;
    const full: zpui.scene.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = content.width * s, .height = content.height * s } } };
    const Q = struct {
        fn quad(x: f32, y: f32, w: f32, h: f32, r: f32, c: color.Hsla, sc: f32, mask: zpui.scene.ContentMask) zpui.scene.Quad {
            return .{
                .bounds = .{ .origin = .{ .x = x * sc, .y = y * sc }, .size = .{ .width = w * sc, .height = h * sc } },
                .content_mask = mask,
                .background = color.solidBackground(c),
                .corner_radii = .all(r * sc),
            };
        }
    };
    // Translucent tint over the blurred backdrop.
    try app.scene.insertQuad(gpa, Q.quad(0, 0, content.width, content.height, 0, color.hsla(0.62, 0.2, 0.12, 0.55), s, full));
    try app.scene.insertQuad(gpa, Q.quad(40, 60, 220, 140, 16, color.rgb(0x3b82f6).toHsla(), s, full));
    try app.scene.insertQuad(gpa, Q.quad(290, 60, 220, 140, 32, color.rgb(0xef4444).toHsla(), s, full));
    var bordered = Q.quad(540, 60, 200, 140, 8, color.hsla(0, 0, 1, 0.08), s, full);
    bordered.border_widths = .all(2 * s);
    bordered.border_color = color.rgb(0x10b981).toHsla();
    try app.scene.insertQuad(gpa, bordered);
    // Follows the mouse.
    try app.scene.insertQuad(gpa, Q.quad(app.mouse.x - 30, app.mouse.y - 30, 60, 60, 30, color.rgb(0xfacc15).toHsla(), s, full));
    app.scene.finish();
}

fn onInput(_: ?*anyopaque, event: zpui.input.PlatformInput) platform.DispatchEventResult {
    switch (event) {
        .key_down => |e| std.debug.print("key_down key=\"{s}\" char={?s} mods=ctrl:{} alt:{} shift:{} cmd:{} fn:{} held={}\n", .{
            e.keystroke.key,             e.keystroke.key_char,           e.keystroke.modifiers.control,  e.keystroke.modifiers.alt,
            e.keystroke.modifiers.shift, e.keystroke.modifiers.platform, e.keystroke.modifiers.function, e.is_held,
        }),
        .key_up => |e| std.debug.print("key_up key=\"{s}\"\n", .{e.keystroke.key}),
        .modifiers_changed => |e| std.debug.print("modifiers ctrl:{} alt:{} shift:{} cmd:{} caps:{}\n", .{
            e.modifiers.control, e.modifiers.alt, e.modifiers.shift, e.modifiers.platform, e.capslock,
        }),
        .mouse_move => |e| {
            app.mouse = e.position;
            if (app.window) |w| w.requestFrame();
        },
        .mouse_down => |e| std.debug.print("mouse_down {s} at ({d:.1},{d:.1}) clicks={d} first_mouse={}\n", .{ @tagName(e.button), e.position.x, e.position.y, e.click_count, e.first_mouse }),
        .scroll_wheel => |e| switch (e.delta) {
            .pixels => |d| std.debug.print("scroll px ({d:.1},{d:.1}) {s}\n", .{ d.x, d.y, @tagName(e.touch_phase) }),
            .lines => |d| std.debug.print("scroll lines ({d:.1},{d:.1})\n", .{ d.x, d.y }),
        },
        else => {},
    }
    return .{};
}

fn onResize(_: ?*anyopaque, size: platform.Size, scale: f32) void {
    std.debug.print("resize {d}x{d} @{d}x\n", .{ size.width, size.height, scale });
    if (app.window) |w| w.requestFrame();
}

fn onActive(_: ?*anyopaque, active: bool) void {
    std.debug.print("active={}\n", .{active});
}

fn onAppearance(_: ?*anyopaque) void {
    if (app.window) |w| std.debug.print("appearance changed: {s}\n", .{@tagName(w.appearance())});
}

fn onClose(_: ?*anyopaque) void {
    std.debug.print("window closed\n", .{});
    app.window = null;
    app.platform.quit();
}

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

fn onWatchdog(_: *anyopaque) void {
    if (app.smoke_done) return;
    std.debug.print(
        \\FAIL: only {d}/{d} frames rendered within {d}s (display link fallback active: {}).
        \\      Check that the runner has a GUI session and the window is not occluded.
        \\
    , .{ app.frames, app.smoke_frames.?, watchdog_ns / std.time.ns_per_s, app.using_fallback_timer });
    app.exit_code = 1;
    app.smoke_done = true;
    app.platform.quit();
}

fn onFallbackCheck(_: *anyopaque) void {
    if (app.smoke_done or app.frames > 0) return;
    std.debug.print("WARN: no display-link frames after {d}s; driving frames with a timer to finish the smoke test\n", .{fallback_after_ns / std.time.ns_per_s});
    app.using_fallback_timer = true;
    onFallbackTick(&app);
}

fn onFallbackTick(_: *anyopaque) void {
    if (app.smoke_done) return;
    onRequestFrame(null, false);
    app.platform.dispatcher().dispatchAfter(16 * std.time.ns_per_ms, .{ .ctx = &app, .run = onFallbackTick });
}

fn finishSmoke(window: platform.Window) void {
    std.debug.print("rendered {d} frames; capturing\n", .{app.frames});
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(app.io, "zig-out") catch {};

    // 1) Same scene through an offscreen renderer: verifies the Metal pipeline end to end.
    captureOffscreen(window) catch |err| {
        std.debug.print("FAIL: offscreen capture: {s}\n", .{@errorName(err)});
        app.exit_code = 1;
    };
    // 2) The real window (compositor output, includes the blur). Best effort: may
    //    need Screen Recording permission on newer macOS.
    captureWindow(window) catch |err| std.debug.print("WARN: window capture unavailable: {s}\n", .{@errorName(err)});

    app.platform.quit();
}

fn captureOffscreen(window: platform.Window) !void {
    const gpa = app.gpa;
    const scale = window.scaleFactor();
    const content = window.contentSize();
    const size: zpui.Size(zpui.DevicePixels) = .{
        .width = @intFromFloat(@round(content.width * scale)),
        .height = @intFromFloat(@round(content.height * scale)),
    };
    var r = try Renderer.init(gpa, .{ .size = size, .transparent = true });
    defer r.deinit();
    try buildScene(content, scale);
    try r.drawScene(&app.scene, size, scale, .{});
    const pixels = try r.readPixels(gpa);
    defer gpa.free(pixels);
    unpremultiply(pixels);

    // Sanity: the blue quad's center must be blue-ish and opaque.
    const w: usize = @intCast(size.width);
    const cx: usize = @intFromFloat(150 * scale);
    const cy: usize = @intFromFloat(130 * scale);
    const px = pixels[(cy * w + cx) * 4 ..][0..4];
    std.debug.print("offscreen pixel at blue quad: rgba({d},{d},{d},{d})\n", .{ px[0], px[1], px[2], px[3] });
    try writePng("zig-out/mac-window-offscreen.png", @intCast(size.width), @intCast(size.height), pixels);
    if (!(px[2] > 200 and px[0] < 120 and px[3] > 250)) return error.UnexpectedPixelColor;
}

fn captureWindow(window: platform.Window) !void {
    const cf = mac.cf;
    const number = mac.MacWindow.fromWindow(window).windowNumber();
    const create_image = cf.cgWindowListCreateImage() orelse return error.CGWindowListCreateImageUnavailable;
    const image = create_image(cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, number, cf.kCGWindowImageBoundsIgnoreFraming | cf.kCGWindowImageBestResolution) orelse
        return error.CGWindowListCreateImageReturnedNull;
    defer cf.CGImageRelease(image);
    const w = cf.CGImageGetWidth(image);
    const h = cf.CGImageGetHeight(image);
    if (w == 0 or h == 0) return error.EmptyImage;
    const pixels = try app.gpa.alloc(u8, w * h * 4);
    defer app.gpa.free(pixels);
    @memset(pixels, 0);
    const space = cf.CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, cf.kCGImageAlphaPremultipliedLast | cf.kCGBitmapByteOrder32Big) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    cf.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    unpremultiply(pixels);
    try writePng("zig-out/mac-window.png", @intCast(w), @intCast(h), pixels);
}

fn writePng(path: []const u8, w: u32, h: u32, rgba: []const u8) !void {
    const encoded = try png.encode(app.gpa, w, h, rgba);
    defer app.gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = encoded });
    std.debug.print("wrote {s} ({d}x{d})\n", .{ path, w, h });
}

fn unpremultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}
