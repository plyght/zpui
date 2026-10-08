//! Windows platform demo: `zig build windows-window`.
//!
//! Opens three windows on the Win32 backend:
//!   * a normal window with rounded quads, a border, a shadow, a path, DirectWrite text
//!     and a quad that follows the mouse;
//!   * a transparent, always-on-top, click-through-outside-the-pet overlay pinned to the
//!     bottom-right corner of the work area (`WindowKind.overlay` + `setInputRegion`),
//!     which bobs when the global input monitor reports a key press; dragging its corner
//!     handle resizes it (aspect-locked, anchored corner fixed);
//!   * a settings panel with Mica and real Win32 controls (checkbox, toggle, trackbar,
//!     segmented buttons, combo box, up-down) placed through the native-controls API.
//!
//! Smoke test (CI): `ZPUI_SMOKE_FRAMES=30 zig build windows-window` renders 30 frames
//! per window, then writes
//!   zig-out/windows-offscreen.png  (the main scene through an offscreen D3D11 renderer,
//!                                   pixel-checked)
//!   zig-out/windows-main.png, windows-overlay.png, windows-settings.png
//!                                  (each window's presented swapchain frame, read back)
//!   zig-out/windows-desktop.png    (screen capture of the overlay + settings windows:
//!                                   transparency over the desktop and the native controls)
//! and exits 0, or exits 1 with a diagnostic when frames never arrive or the offscreen
//! image is wrong.

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");

const win = zpui.windows_platform;
const w = win.win32;
const platform = zpui.platform;
const color = zpui.color;
const Scene = zpui.Scene;
const Renderer = zpui.renderer.Renderer;

const watchdog_ns = 40 * std.time.ns_per_s;

const Kind = enum { main, overlay, settings };

const View = struct {
    kind: Kind,
    window: ?platform.Window = null,
    scene: Scene = .{},
    frames: u64 = 0,
    captured: bool = false,
    controls: [6]?platform.NativeViewId = @splat(null),
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    platform: platform.Platform,
    text: zpui.text.TextSystem,
    views: [3]View = .{ .{ .kind = .main }, .{ .kind = .overlay }, .{ .kind = .settings } },
    mouse: zpui.Point(f32) = .{ .x = 400, .y = 300 },
    key_presses: u64 = 0,
    bob: f32 = 0,
    smoke_frames: ?u64 = null,
    done: bool = false,
    exit_code: u8 = 0,
    arena: std.heap.ArenaAllocator,
    // Overlay corner-handle drag.
    dragging: bool = false,
    drag_start_mouse: platform.Point = .zero,
    drag_start_size: f32 = 0,
    pet_size: f32 = 200,
    slider_value: f64 = 0.4,
    /// zpui.audio (WASAPI): a soft click per global key press, muted while another app
    /// plays audio or records (ActivityMonitor).
    audio: ?*zpui.audio.Audio = null,
    click: ?zpui.audio.SoundId = null,
    activity: ?*zpui.audio.ActivityMonitor = null,
    idle_frames_start: u64 = 0,
    idle_cpu_start: u64 = 0,
};

var app: App = undefined;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const smoke: ?u64 = if (init.environ_map.get("ZPUI_SMOKE_FRAMES")) |v| std.fmt.parseInt(u64, v, 10) catch 30 else null;
    const plat = try win.create(gpa, .{});
    app = .{
        .gpa = gpa,
        .io = init.io,
        .platform = plat,
        .text = .init(gpa, plat.textSystem()),
        .smoke_frames = smoke,
        .arena = .init(gpa),
    };
    plat.vtable.setCallbacks(plat.ptr, .{ .quit = onQuit });
    initAudio();
    defer if (app.activity) |m| m.deinit();
    defer if (app.audio) |a| a.deinit();
    std.debug.print("zpui windows-window: smoke={?d}\n", .{smoke});
    plat.run(.{ .func = onLaunch });
    std.debug.print("run loop exited (exit code {d}); frames main={d} overlay={d} settings={d}; global key presses={d}\n", .{
        app.exit_code, app.views[0].frames, app.views[1].frames, app.views[2].frames, app.key_presses,
    });
    if (app.exit_code != 0) std.process.exit(app.exit_code);
}

fn initAudio() void {
    const a = zpui.audio.Audio.init(app.gpa, .{}) catch |err| {
        std.debug.print("audio unavailable: {t}\n", .{err});
        return;
    };
    app.audio = a;
    const pcm = zpui.audio.synthesizeClick(app.gpa, a.sampleRate(), 1) catch return;
    defer app.gpa.free(pcm);
    app.click = a.loadPcm(pcm, a.sampleRate()) catch null;
    app.activity = zpui.audio.ActivityMonitor.init(app.gpa, .{ .audio = a }) catch null;
    std.debug.print("audio: {d} Hz, activity monitor: {s}\n", .{ a.sampleRate(), if (app.activity) |m| m.backendName() else "none" });
}

fn onQuit(_: ?*anyopaque) void {
    std.debug.print("quit requested\n", .{});
}

fn onLaunch(_: ?*anyopaque, _: void) void {
    const p = app.platform;
    var displays: [8]platform.Display = undefined;
    const n = p.vtable.displays(p.ptr, &displays);
    for (displays[0..n]) |d| std.debug.print("display {d}: {d}x{d} @{d}x visible {d}x{d}{s}\n", .{
        d.id, d.bounds.size.width, d.bounds.size.height, d.scale_factor, d.visible_bounds.size.width, d.visible_bounds.size.height, if (d.primary) " (primary)" else "",
    });
    std.debug.print("appearance={t} reduced_motion={} input_permission={t}\n", .{ p.vtable.windowAppearance(p.ptr), p.vtable.prefersReducedMotion(p.ptr), p.inputPermission() });

    open(.main, .{
        .bounds = .{ .origin = .{ .x = 80, .y = 80 }, .size = .{ .width = 800, .height = 560 } },
        .titlebar = .{ .title = "zpui windows-window" },
        .min_size = .{ .width = 320, .height = 240 },
    });
    open(.settings, .{
        .bounds = .{ .origin = .{ .x = 920, .y = 80 }, .size = .{ .width = 380, .height = 360 } },
        .titlebar = .{ .title = "typebud settings" },
        .background = .blurred,
    });
    open(.overlay, .{
        .bounds = .{ .origin = .zero, .size = .{ .width = app.pet_size, .height = app.pet_size } },
        .titlebar = null,
        .kind = .overlay,
        .focus = false,
        .background = .transparent,
        .anchor = .{ .corner = .bottom_right, .margin = .{ .x = 24, .y = 24 } },
    });
    if (app.views[1].window) |ow| setPetRegion(ow);

    const status = p.startGlobalInputMonitor(.{ .func = onGlobalInput });
    std.debug.print("global input monitor: {t}\n", .{status});
    var fg_buf: [512]u8 = undefined;
    if (p.foregroundApp(&fg_buf)) |fg| std.debug.print("foreground app: {s} ({s})\n", .{ fg.name, fg.id });

    if (app.smoke_frames != null) p.dispatcher().dispatchAfter(watchdog_ns, .{ .ctx = &app, .run = onWatchdog });
}

fn open(kind: Kind, params: platform.WindowParams) void {
    const v = &app.views[@backingInt(kind)];
    const window = app.platform.openWindow(params) catch |err| {
        std.debug.print("FAIL: openWindow({t}): {t}\n", .{ kind, err });
        app.exit_code = 1;
        app.platform.quit();
        return;
    };
    v.window = window;
    window.setCallbacks(.{
        .ctx = v,
        .request_frame = onRequestFrame,
        .input = onInput,
        .resize = onResize,
        .close = onClose,
        .native_control = onNativeControl,
    });
    if (kind == .settings) attachControls(v, window);
    window.requestFrame();
    std.debug.print("{t} window: content {d}x{d} @{d}x\n", .{ kind, window.contentSize().width, window.contentSize().height, window.scaleFactor() });
}

fn viewOf(ctx: ?*anyopaque) *View {
    return @ptrCast(@alignCast(ctx.?));
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

fn onRequestFrame(ctx: ?*anyopaque, _: bool) void {
    const v = viewOf(ctx);
    const window = v.window orelse return;
    if (v.kind == .settings) placeControls(v, window);
    buildScene(v, window.contentSize(), window.scaleFactor()) catch |err| {
        std.debug.print("scene error: {t}\n", .{err});
        return;
    };
    const smoke_target = app.smoke_frames;
    const capture_now = if (smoke_target) |t| v.frames + 1 >= t and !v.captured else false;
    if (capture_now) rendererOf(window).requestCapture();
    window.draw(&v.scene) catch |err| {
        std.debug.print("draw error ({t}): {t}\n", .{ v.kind, err });
        return;
    };
    v.frames += 1;
    if (capture_now) {
        v.captured = true;
        saveCapture(v, window);
        maybeFinish();
    }
    if (smoke_target != null and !app.done) window.requestFrame();
}

fn rendererOf(window: platform.Window) *zpui.windows_platform.Renderer {
    return &(win.Window.fromWindow(window).renderer.?);
}

fn q(x: f32, y: f32, wd: f32, h: f32, r: f32, c: color.Hsla, s: f32, mask: zpui.scene.ContentMask) zpui.scene.Quad {
    return .{
        .bounds = .{ .origin = .{ .x = x * s, .y = y * s }, .size = .{ .width = wd * s, .height = h * s } },
        .content_mask = mask,
        .background = color.solidBackground(c),
        .corner_radii = .all(r * s),
    };
}

fn hex(v: u32) color.Hsla {
    return color.rgb(v).toHsla();
}

fn buildScene(v: *View, content: platform.Size, s: f32) !void {
    const gpa = app.gpa;
    const sc = &v.scene;
    sc.clear(gpa);
    _ = app.arena.reset(.retain_capacity);
    const full: zpui.scene.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = content.width * s, .height = content.height * s } } };
    switch (v.kind) {
        .main => {
            try sc.insertQuad(gpa, q(0, 0, content.width, content.height, 0, hex(0xf4f4f6), s, full));
            try sc.insertShadow(gpa, .{
                .blur_radius = 12 * s,
                .bounds = .{ .origin = .{ .x = 40 * s, .y = 64 * s }, .size = .{ .width = 220 * s, .height = 140 * s } },
                .corner_radii = .all(16 * s),
                .content_mask = full,
                .color = color.hsla(0, 0, 0, 0.25),
            });
            try sc.insertQuad(gpa, q(40, 60, 220, 140, 16, hex(0x3b82f6), s, full));
            try sc.insertQuad(gpa, q(290, 60, 220, 140, 32, hex(0xef4444), s, full));
            var bordered = q(540, 60, 200, 140, 8, color.hsla(0, 0, 1, 1), s, full);
            bordered.border_widths = .all(2 * s);
            bordered.border_color = hex(0x10b981);
            try sc.insertQuad(gpa, bordered);
            // A path (triangle with a curved side).
            var path = zpui.scene.Path.init(.{ .x = 60 * s, .y = 420 * s });
            path.content_mask = full;
            path.color = color.solidBackground(hex(0x8b5cf6));
            try path.lineTo(gpa, .{ .x = 200 * s, .y = 420 * s });
            try path.curveTo(gpa, .{ .x = 130 * s, .y = 300 * s }, .{ .x = 220 * s, .y = 320 * s });
            try path.lineTo(gpa, .{ .x = 60 * s, .y = 420 * s });
            try sc.insertPath(gpa, path);
            try text(v, "Hello from zpui on Windows — DirectWrite + D3D11", 40, 250, 22, hex(0x18181b), s, full);
            try text(v, "Overlay pet in the corner reacts to typing anywhere.", 40, 284, 15, hex(0x52525b), s, full);
            try sc.insertQuad(gpa, q(app.mouse.x - 24, app.mouse.y - 24, 48, 48, 24, hex(0xfacc15), s, full));
        },
        .overlay => {
            // Transparent background: only the pet is drawn.
            const size = @min(content.width, content.height);
            const pad = size * 0.08;
            const body = size - 2 * pad;
            const bob = app.bob;
            try sc.insertShadow(gpa, .{
                .blur_radius = 10 * s,
                .bounds = .{ .origin = .{ .x = pad * s, .y = (pad + 6 - bob) * s }, .size = .{ .width = body * s, .height = body * s } },
                .corner_radii = .all(body * 0.45 * s),
                .content_mask = full,
                .color = color.hsla(0, 0, 0, 0.35),
            });
            try sc.insertQuad(gpa, q(pad, pad - bob, body, body, body * 0.45, hex(0xfb923c), s, full));
            const eye = body * 0.1;
            try sc.insertQuad(gpa, q(pad + body * 0.28, pad + body * 0.35 - bob, eye, eye * 1.4, eye / 2, hex(0x1c1917), s, full));
            try sc.insertQuad(gpa, q(pad + body * 0.62, pad + body * 0.35 - bob, eye, eye * 1.4, eye / 2, hex(0x1c1917), s, full));
            // Resize handle (bottom-left, away from the anchored bottom-right corner).
            try sc.insertQuad(gpa, q(2, size - 18, 16, 16, 4, color.hsla(0, 0, 1, if (app.dragging) 0.95 else 0.6), s, full));
        },
        .settings => {
            // Translucent tint over Mica; controls are native children placed on top.
            try sc.insertQuad(gpa, q(0, 0, content.width, content.height, 0, color.hsla(0.6, 0.1, 0.5, 0.08), s, full));
            const labels = [_][]const u8{ "Show pet", "Bounce on keys", "Size", "Mood", "Character", "Speed" };
            for (labels, 0..) |l, i| try text(v, l, 20, 34 + @as(f32, @floatFromInt(i)) * 48, 14, hex(0x27272a), s, full);
        },
    }
    sc.finish();
}

/// One line of DirectWrite text as monochrome sprites in `v`'s window atlas.
fn text(v: *View, str: []const u8, x: f32, baseline: f32, size: f32, c: color.Hsla, s: f32, mask: zpui.scene.ContentMask) !void {
    const sc = &v.scene;
    const ts = &app.text;
    const font_id = ts.fontId(zpui.text.font("system-ui")) catch return; // Segoe UI
    const pts = app.platform.textSystem();
    const layout = try pts.vtable.layoutLine(pts.ptr, app.arena.allocator(), str, size, &.{.{ .len = str.len, .font_id = font_id }});
    const atlas = (v.window orelse return).spriteAtlas();
    for (layout.runs) |run| for (run.glyphs) |g| {
        const origin: zpui.Point(f32) = .{ .x = x + g.position.x, .y = baseline + g.position.y };
        const r = zpui.text.line.glyphRenderParams(run.font_id, g.id, size, origin, s, false);
        const sprite = (ts.rasterizeToAtlas(atlas, r.params, r.origin) catch continue) orelse continue;
        try sc.insertMonochromeSprite(app.gpa, .{
            .bounds = sprite.bounds,
            .content_mask = mask,
            .color = c,
            .tile = sprite.tile,
        });
    };
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

fn onInput(ctx: ?*anyopaque, event: zpui.input.PlatformInput) platform.DispatchEventResult {
    const v = viewOf(ctx);
    const window = v.window orelse return .{};
    switch (event) {
        .mouse_move => |e| {
            if (v.kind == .main) {
                app.mouse = e.position;
                window.requestFrame();
            }
            if (v.kind == .overlay and app.dragging) {
                // Aspect-locked resize from the bottom-left handle; the bottom-right
                // corner stays anchored. Screen coordinates keep tracking outside.
                const now = window.screenMousePosition() orelse return .{};
                const start: platform.Size = .{ .width = app.drag_start_size, .height = app.drag_start_size };
                const delta: platform.Point = .{ .x = now.x - app.drag_start_mouse.x, .y = now.y - app.drag_start_mouse.y };
                const next = platform.desktop.aspectResize(.bottom_right, start, delta, 80, 480).width;
                if (next != app.pet_size) {
                    app.pet_size = next;
                    window.vtable.resize(window.ptr, .{ .width = next, .height = next });
                    setPetRegion(window);
                }
            }
        },
        .mouse_down => |e| if (v.kind == .overlay) {
            const size = window.contentSize().height;
            if (e.position.x < 24 and e.position.y > size - 24) {
                app.dragging = true;
                app.drag_start_mouse = window.screenMousePosition() orelse return .{};
                app.drag_start_size = app.pet_size;
                window.requestFrame();
            }
        },
        .mouse_up => if (v.kind == .overlay and app.dragging) {
            app.dragging = false;
            window.requestFrame();
        },
        .key_down => |e| std.debug.print("key_down key=\"{s}\" char={?s}\n", .{ e.keystroke.key, e.keystroke.key_char }),
        else => {},
    }
    return .{};
}

/// Only the pet's body (plus its resize handle) takes the mouse; the rest of the
/// overlay is click-through.
fn setPetRegion(window: platform.Window) void {
    const size = window.contentSize().height;
    const pad = size * 0.08;
    const rects = [_]platform.Bounds{
        .{ .origin = .{ .x = pad, .y = pad }, .size = .{ .width = size - 2 * pad, .height = size - 2 * pad } },
        .{ .origin = .{ .x = 0, .y = size - 24 }, .size = .{ .width = 24, .height = 24 } },
    };
    window.setInputRegion(&rects);
}

fn onGlobalInput(_: ?*anyopaque, e: platform.GlobalInputEvent) void {
    if (e.kind != .key_down) return;
    app.key_presses += 1;
    app.bob = if (e.key_x < 0.5) 6 else 10;
    if (app.audio) |a| if (app.click) |c| {
        if (app.activity) |m| _ = m.dispatch();
        const muted = if (app.activity) |m| m.shouldMute() else false;
        if (!muted and app.smoke_frames == null) a.play(c, .{ .gain = 0.35, .pan = (e.key_x - 0.5) * 0.6 });
    };
    const ow = app.views[1].window orelse return;
    ow.requestFrame();
    app.platform.dispatcher().dispatchAfter(120 * std.time.ns_per_ms, .{ .ctx = &app, .run = settle });
}

fn settle(_: *anyopaque) void {
    app.bob = 0;
    if (app.views[1].window) |ow| ow.requestFrame();
}

fn onResize(ctx: ?*anyopaque, size: platform.Size, scale: f32) void {
    const v = viewOf(ctx);
    if (app.smoke_frames == null) std.debug.print("{t} resize {d}x{d} @{d}x\n", .{ v.kind, size.width, size.height, scale });
    if (v.window) |win_| win_.requestFrame();
}

fn onClose(ctx: ?*anyopaque) void {
    const v = viewOf(ctx);
    v.window = null;
    if (v.kind != .overlay) app.platform.quit();
}

// ---------------------------------------------------------------------------
// Native controls
// ---------------------------------------------------------------------------

fn controlStates() [6]platform.NativeControlState {
    return .{
        .{ .kind = .switch_, .on = true, .label = "Show pet" },
        .{ .kind = .checkbox, .on = true, .title = "Enabled", .label = "Bounce on keys" },
        .{ .kind = .slider, .value = app.slider_value, .min = 0, .max = 1 },
        .{ .kind = .segmented, .items = &.{ "Calm", "Playful", "Hyper" }, .selected = 1 },
        .{ .kind = .popup, .items = &.{ "Cat", "Dog", "Blob" }, .selected = 0 },
        .{ .kind = .stepper, .value = 3, .min = 1, .max = 10, .step = 1 },
    };
}

fn attachControls(v: *View, window: platform.Window) void {
    if (!window.hasNativeControls()) {
        std.debug.print("WARN: window has no native controls\n", .{});
        return;
    }
    for (controlStates(), 0..) |st, i| {
        v.controls[i] = window.attachNativeControl(st, .above_content) catch |err| blk: {
            std.debug.print("WARN: attach {t}: {t}\n", .{ st.kind, err });
            break :blk null;
        };
    }
}

fn placeControls(v: *View, window: platform.Window) void {
    for (controlStates(), 0..) |st, i| {
        const id = v.controls[i] orelse continue;
        const m = window.measureNativeControl(st) orelse platform.Size{ .width = 120, .height = 24 };
        const width = if (m.width > 0) m.width else 180;
        const b: platform.Bounds = .{ .origin = .{ .x = 170, .y = 18 + @as(f32, @floatFromInt(i)) * 48 }, .size = .{ .width = width, .height = m.height } };
        window.placeNativeView(id, .{ .bounds = b, .clip = b });
    }
}

fn onNativeControl(_: ?*anyopaque, view: platform.NativeViewId, event: platform.NativeControlEvent) void {
    std.debug.print("native control {d}: {t} on={} value={d:.2} index={d}\n", .{ @backingInt(view), event.kind, event.on, event.value, event.index });
    if (event.kind == .slider) app.slider_value = event.value;
}

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

fn onWatchdog(_: *anyopaque) void {
    if (app.done) return;
    std.debug.print("FAIL: frames main={d} overlay={d} settings={d} of {d} within {d}s\n", .{
        app.views[0].frames, app.views[1].frames, app.views[2].frames, app.smoke_frames.?, watchdog_ns / std.time.ns_per_s,
    });
    app.exit_code = 1;
    app.done = true;
    app.platform.quit();
}

fn saveCapture(v: *View, window: platform.Window) void {
    const cap = rendererOf(window).takeCapture() orelse {
        std.debug.print("WARN: no capture for {t}\n", .{v.kind});
        return;
    };
    defer app.gpa.free(cap.rgba);
    unpremultiply(cap.rgba);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "zig-out/windows-{t}.png", .{v.kind}) catch return;
    writePng(name, cap.width, cap.height, cap.rgba) catch |err| std.debug.print("WARN: {s}: {t}\n", .{ name, err });
}

fn maybeFinish() void {
    for (app.views) |v| if (v.window != null and !v.captured) return;
    if (app.done) return;
    app.done = true;
    std.debug.print("all windows rendered; capturing\n", .{});
    captureOffscreen() catch |err| {
        std.debug.print("FAIL: offscreen capture: {t}\n", .{err});
        app.exit_code = 1;
    };
    captureDesktop() catch |err| std.debug.print("WARN: desktop capture unavailable: {t}\n", .{err});
    // Idle check: after frames already requested have drained, nothing may draw.
    app.platform.dispatcher().dispatchAfter(300 * std.time.ns_per_ms, .{ .ctx = &app, .run = onIdleStart });
}

fn onIdleStart(_: *anyopaque) void {
    app.idle_frames_start = totalFrames();
    app.idle_cpu_start = cpuTimeNs();
    app.platform.dispatcher().dispatchAfter(2 * std.time.ns_per_s, .{ .ctx = &app, .run = onIdleDone });
}

fn totalFrames() u64 {
    return app.views[0].frames + app.views[1].frames + app.views[2].frames;
}

fn onIdleDone(_: *anyopaque) void {
    const frames = totalFrames() - app.idle_frames_start;
    const cpu_ms = (cpuTimeNs() - app.idle_cpu_start) / std.time.ns_per_ms;
    std.debug.print("idle: {d} frames rendered, {d} ms CPU in 2 s (global input monitor running)\n", .{ frames, cpu_ms });
    if (frames != 0) {
        std.debug.print("FAIL: frames were drawn while idle\n", .{});
        app.exit_code = 1;
    }
    app.platform.quit();
}

fn cpuTimeNs() u64 {
    var times: [4]u64 = .{ 0, 0, 0, 0 };
    if (w.GetProcessTimes(w.GetCurrentProcess(), &times[0], &times[1], &times[2], &times[3]) == 0) return 0;
    return (times[2] + times[3]) * 100;
}

fn captureOffscreen() !void {
    const gpa = app.gpa;
    const window = app.views[0].window orelse return error.NoMainWindow;
    const scale = window.scaleFactor();
    const content = window.contentSize();
    const size: zpui.Size(zpui.DevicePixels) = .{ .width = @intFromFloat(@round(content.width * scale)), .height = @intFromFloat(@round(content.height * scale)) };
    var r = try Renderer.init(gpa, .{ .size = size, .transparent = true });
    defer r.deinit();
    // Glyph tiles live in the window renderer's atlas; draw the quads-only part offscreen.
    const v = &app.views[0];
    try buildScene(v, content, scale);
    v.scene.monochrome_sprites.clearRetainingCapacity();
    try r.drawScene(&v.scene, size, scale, .{});
    const pixels = try r.readPixels(gpa);
    defer gpa.free(pixels);
    unpremultiply(pixels);
    const wd: usize = @intCast(size.width);
    const cx: usize = @intFromFloat(150 * scale);
    const cy: usize = @intFromFloat(130 * scale);
    const px = pixels[(cy * wd + cx) * 4 ..][0..4];
    std.debug.print("offscreen pixel at blue quad: rgba({d},{d},{d},{d})\n", .{ px[0], px[1], px[2], px[3] });
    try writePng("zig-out/windows-offscreen.png", @intCast(size.width), @intCast(size.height), pixels);
    if (!(px[2] > 200 and px[0] < 120 and px[3] > 250)) return error.UnexpectedPixelColor;
}

/// GDI capture of the composited screen (DWM output) around the overlay and settings
/// windows: shows the overlay's transparency and the native controls.
fn captureDesktop() !void {
    var union_rect: ?w.RECT = null;
    for ([_]usize{ 1, 2 }) |i| {
        const window = app.views[i].window orelse continue;
        var r: w.RECT = .{};
        _ = w.GetWindowRect(win.Window.fromWindow(window).hwnd, &r);
        union_rect = if (union_rect) |u| .{ .left = @min(u.left, r.left), .top = @min(u.top, r.top), .right = @max(u.right, r.right), .bottom = @max(u.bottom, r.bottom) } else r;
    }
    var r = union_rect orelse return error.NoWindows;
    r.left -= 16;
    r.top -= 16;
    r.right += 16;
    r.bottom += 16;
    const wd = r.width();
    const ht = r.height();
    if (wd <= 0 or ht <= 0) return error.EmptyRect;
    // Give DWM a frame to compose what we presented.
    _ = w.DwmFlush();
    const screen = w.GetDC(null) orelse return error.NoDC;
    defer _ = w.ReleaseDC(null, screen);
    const mem = w.CreateCompatibleDC(screen) orelse return error.NoDC;
    defer _ = w.DeleteDC(mem);
    var bits: ?*anyopaque = null;
    const bmi: w.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = wd, .biHeight = -ht } };
    const bmp = w.CreateDIBSection(screen, &bmi, 0, &bits, null, 0) orelse return error.NoBitmap;
    defer _ = w.DeleteObject(bmp);
    const old = w.SelectObject(mem, bmp);
    defer _ = w.SelectObject(mem, old.?);
    if (w.BitBlt(mem, 0, 0, wd, ht, screen, r.left, r.top, w.SRCCOPY | w.CAPTUREBLT) == 0) return error.BitBltFailed;
    const n: usize = @intCast(wd * ht * 4);
    const src: [*]const u8 = @ptrCast(bits.?);
    const out = try app.gpa.alloc(u8, n);
    defer app.gpa.free(out);
    var i: usize = 0;
    while (i < n) : (i += 4) {
        out[i] = src[i + 2];
        out[i + 1] = src[i + 1];
        out[i + 2] = src[i];
        out[i + 3] = 255;
    }
    try writePng("zig-out/windows-desktop.png", @intCast(wd), @intCast(ht), out);
}

fn writePng(path: []const u8, wd: u32, h: u32, rgba: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(app.io, "zig-out") catch {};
    const encoded = try png.encode(app.gpa, wd, h, rgba);
    defer app.gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = encoded });
    std.debug.print("wrote {s} ({d}x{d})\n", .{ path, wd, h });
}

fn unpremultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}
