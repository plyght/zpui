//! Linux platform demo (`zig build linux-window -- [--transparent] [--frames N] [--backend x11|wayland]`).
//!
//! Opens a 900x600 window and draws a small scene every frame: a rounded panel, a few
//! cards, an animated bar, and a dot that follows the mouse. Clicking cycles the palette,
//! scrolling moves the dot's ring, and key events are printed to stderr. `--frames N`
//! quits after N frames (for scripted screenshots); `--clipboard` round-trips a string
//! through the clipboard on each click and `--read-clipboard` prints it at launch.

const std = @import("std");
const zpui = @import("zpui");
const linux = zpui.linux_platform;
const platform = zpui.platform;
const scene_mod = zpui.scene;
const color = zpui.color;

const Demo = struct {
    gpa: std.mem.Allocator,
    plat: platform.Platform,
    window: platform.Window = undefined,
    scene: scene_mod.Scene = .{},
    transparent: bool,
    max_frames: ?u64,
    clipboard_test: bool,
    read_clipboard: bool = false,
    frames: u64 = 0,
    mouse: platform.Point = .{ .x = 450, .y = 300 },
    palette: usize = 0,
    ring: f32 = 0,
    pressed: bool = false,
    start_ns: u64 = 0,

    const palettes = [_][3]u32{
        .{ 0x3b82f6, 0xf59e0b, 0x10b981 },
        .{ 0xef4444, 0x8b5cf6, 0x06b6d4 },
        .{ 0xec4899, 0x84cc16, 0xf97316 },
    };

    fn hex(v: u32, a: f32) color.Hsla {
        var h = color.rgb(v).toHsla();
        h.a = a;
        return h;
    }

    fn quad(s: f32, mask: scene_mod.ContentMask, x: f32, y: f32, w: f32, h: f32, r: f32, bg: color.Hsla) scene_mod.Quad {
        return .{
            .bounds = .{ .origin = .{ .x = x * s, .y = y * s }, .size = .{ .width = w * s, .height = h * s } },
            .content_mask = mask,
            .background = color.solidBackground(bg),
            .corner_radii = .all(r * s),
        };
    }

    fn buildScene(d: *Demo) !void {
        const gpa = d.gpa;
        const size = d.window.contentSize();
        const s = d.window.scaleFactor();
        const sc = &d.scene;
        sc.clear(gpa);
        const mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = size.width * s, .height = size.height * s } } };
        const pal = palettes[d.palette % palettes.len];

        // Background panel (inset so the transparent corners are visible in transparent mode).
        const panel_alpha: f32 = if (d.transparent) 0.72 else 1;
        try sc.insertQuad(gpa, quad(s, mask, 0, 0, size.width, size.height, if (d.transparent) 24 else 0, hex(0x1f2430, panel_alpha)));
        try sc.insertQuad(gpa, quad(s, mask, 24, 24, size.width - 48, 64, 14, hex(0x2d3445, 1)));

        // Three cards in the current palette.
        const card_w = (size.width - 48 - 2 * 24) / 3;
        for (pal, 0..) |cv, i| {
            const x = 24 + @as(f32, @floatFromInt(i)) * (card_w + 24);
            try sc.insertQuad(gpa, quad(s, mask, x, 112, card_w, 180, 18, hex(cv, 1)));
        }

        // Animated progress bar.
        const t = @as(f32, @floatFromInt((d.plat.dispatcher().now() - d.start_ns) / std.time.ns_per_ms)) / 1000.0;
        const phase = (@sin(t * 2.0) + 1) / 2;
        try sc.insertQuad(gpa, quad(s, mask, 24, 320, size.width - 48, 20, 10, hex(0x3a4256, 1)));
        try sc.insertQuad(gpa, quad(s, mask, 24, 320, 20 + phase * (size.width - 68), 20, 10, hex(pal[0], 1)));

        // Dot following the mouse, with a ring whose size tracks scrolling.
        const ring = 34 + d.ring;
        try sc.insertQuad(gpa, quad(s, mask, d.mouse.x - ring, d.mouse.y - ring, 2 * ring, 2 * ring, ring, hex(0xffffff, 0.25)));
        const r: f32 = if (d.pressed) 18 else 24;
        try sc.insertQuad(gpa, quad(s, mask, d.mouse.x - r, d.mouse.y - r, 2 * r, 2 * r, r, hex(pal[1], 1)));
        sc.finish();
    }

    fn onRequestFrame(ctx: ?*anyopaque, force: bool) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        _ = force;
        d.buildScene() catch |e| std.debug.print("scene error: {t}\n", .{e});
        d.window.draw(&d.scene) catch |e| std.debug.print("draw error: {t}\n", .{e});
        d.frames += 1;
        if (d.max_frames) |m| if (d.frames >= m) {
            std.debug.print("rendered {d} frames, quitting\n", .{d.frames});
            d.plat.quit();
            return;
        };
        d.window.requestFrame();
    }

    fn onInput(ctx: ?*anyopaque, ev: zpui.input.PlatformInput) platform.DispatchEventResult {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .mouse_move => |m| d.mouse = m.position,
            .mouse_down => |m| {
                d.pressed = true;
                d.mouse = m.position;
                d.palette += 1;
                std.debug.print("mouse_down {t} at ({d:.1},{d:.1}) clicks={d}\n", .{ m.button, m.position.x, m.position.y, m.click_count });
                if (d.clipboard_test) d.roundTripClipboard();
            },
            .mouse_up => |m| {
                d.pressed = false;
                std.debug.print("mouse_up {t}\n", .{m.button});
            },
            .scroll_wheel => |w| {
                const dy = switch (w.delta) {
                    .lines => |p| p.y * 4,
                    .pixels => |p| p.y,
                };
                d.ring = std.math.clamp(d.ring + dy, -20, 80);
                std.debug.print("scroll {any}\n", .{w.delta});
            },
            .key_down => |k| std.debug.print("key_down key=\"{s}\" char={?s} mods={any} held={}\n", .{ k.keystroke.key, k.keystroke.key_char, k.keystroke.modifiers, k.is_held }),
            .key_up => |k| std.debug.print("key_up key=\"{s}\"\n", .{k.keystroke.key}),
            .modifiers_changed => |m| std.debug.print("modifiers {any}\n", .{m.modifiers}),
            .mouse_exited => std.debug.print("mouse_exited\n", .{}),
            else => {},
        }
        return .{};
    }

    fn roundTripClipboard(d: *Demo) void {
        d.plat.vtable.writeClipboard(d.plat.ptr, "zpui clipboard ✓");
        if (d.plat.vtable.readClipboard(d.plat.ptr, d.gpa)) |text| {
            defer d.gpa.free(text);
            std.debug.print("clipboard: \"{s}\"\n", .{text});
        } else std.debug.print("clipboard: <empty>\n", .{});
    }

    fn onResize(_: ?*anyopaque, size: platform.Size, scale: f32) void {
        std.debug.print("resize {d}x{d} @{d}\n", .{ size.width, size.height, scale });
    }

    fn onActive(_: ?*anyopaque, active: bool) void {
        std.debug.print("active={}\n", .{active});
    }

    fn onClose(ctx: ?*anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        std.debug.print("window closed\n", .{});
        d.plat.quit();
    }

    fn onLaunch(ctx: ?*anyopaque, _: void) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        d.start_ns = d.plat.dispatcher().now();
        d.window = d.plat.openWindow(.{
            .bounds = .{ .origin = .{ .x = 40, .y = 40 }, .size = .{ .width = 900, .height = 600 } },
            .titlebar = .{ .title = "zpui linux demo" },
            .background = if (d.transparent) .transparent else .opaque_,
            .app_id = "dev.zpui.linux-window",
        }) catch |e| {
            std.debug.print("openWindow failed: {t}\n", .{e});
            d.plat.quit();
            return;
        };
        d.window.setCallbacks(.{
            .ctx = d,
            .request_frame = onRequestFrame,
            .input = onInput,
            .resize = onResize,
            .active_status_change = onActive,
            .close = onClose,
        });
        d.window.requestFrame();
        if (d.read_clipboard) {
            if (d.plat.vtable.readClipboard(d.plat.ptr, d.gpa)) |text| {
                defer d.gpa.free(text);
                std.debug.print("clipboard at launch: \"{s}\"\n", .{text});
            } else std.debug.print("clipboard at launch: <empty>\n", .{});
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var transparent = false;
    var max_frames: ?u64 = null;
    var backend: ?linux.BackendKind = null;
    var clipboard_test = false;
    var read_clipboard = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--transparent")) transparent = true;
        if (std.mem.eql(u8, a, "--clipboard")) clipboard_test = true;
        if (std.mem.eql(u8, a, "--read-clipboard")) read_clipboard = true;
        if (std.mem.eql(u8, a, "--frames") and i + 1 < argv.len) {
            i += 1;
            max_frames = try std.fmt.parseInt(u64, argv[i], 10);
        }
        if (std.mem.eql(u8, a, "--backend") and i + 1 < argv.len) {
            i += 1;
            backend = std.meta.stringToEnum(linux.BackendKind, argv[i]);
        }
    }

    const plat = try linux.create(gpa, .{ .io = init.io, .backend = backend });
    defer plat.deinit();

    var demo: Demo = .{ .gpa = gpa, .plat = plat, .transparent = transparent, .max_frames = max_frames, .clipboard_test = clipboard_test, .read_clipboard = read_clipboard };
    defer demo.scene.deinit(gpa);
    plat.run(.{ .ctx = &demo, .func = Demo.onLaunch });
}
