//! zpui.three demo (`zig build three-demo`): a wooden slab with a grid of
//! instanced, tinted boxes bobbing on it, a few spheres, a sun with soft
//! shadows, and 2D UI over the 3D view (a frosted HUD with backdrop blur).
//!
//!   drag          orbit the camera          scroll   zoom
//!   hover         pick a box (highlighted, shown in the HUD)
//!   T             toggle toon shading + outlines
//!   1 / 2 / 3     quality tier: low (no shadows, FXAA) / medium (shadows, 4x MSAA) / high (+SSAO, tilt-shift)
//!   space         pause / resume the animation
//!
//! Flags: `--frames N` quits after N frames (smoke tests); `--backend x11|wayland` (Linux).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const assets = @import("zeron_assets");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const three = zpui.three;
const M = three.Mat4;
const V = three.Vec3;
const input = zpui.input;

const log = std.log.scoped(.three_demo);

fn hex(v: u32) zpui.Hsla {
    return zpui.rgb(v).toHsla();
}

const theme = struct {
    const bg = hex(0x14110f);
    const panel = hex(0x1d1916);
    const border = hex(0x352d27);
    const text = hex(0xf2ece4);
    const muted = hex(0xa89c8e);
    const accent = hex(0xe0a458);
};

const grid = 9;

const Demo = struct {
    gpa: std.mem.Allocator,
    gfx: *three.Gfx3D,
    scene: *three.Scene3D,
    focus: zpui.FocusHandle,
    box: three.MeshId,
    sphere: three.MeshId,
    slab: three.MeshId,
    orbit: three.Orbit = .{ .target = .new(0, 0.3, 0), .yaw = 0.7, .pitch = 0.68, .distance = 14, .fov_y = std.math.pi / 5.0 },
    drag_from: ?zpui.Point(zpui.Pixels) = null,
    toon: bool = false,
    tier: three.Tier = .medium,
    animate: bool = true,
    time: f32 = 0,
    last_ns: u64 = 0,
    hovered: u32 = 0,
    frames: u64 = 0,

    fn init(window: *Window, cx: *Context(Demo)) Demo {
        const gpa = cx.app.gpa;
        const focus = cx.focusHandle();
        window.focus(focus);
        const gfx = gpa.create(three.Gfx3D) catch @panic("OOM");
        gfx.* = .init(gpa);
        const scene = gpa.create(three.Scene3D) catch @panic("OOM");
        scene.* = .init(gpa, gfx);
        var self: Demo = .{
            .gpa = gpa,
            .gfx = gfx,
            .scene = scene,
            .focus = focus,
            .box = mesh(gpa, gfx, three.shapes.box(gpa, .{ 1, 1, 1 })),
            .sphere = mesh(gpa, gfx, three.shapes.sphere(gpa, 0.5, 20, 32)),
            .slab = mesh(gpa, gfx, three.shapes.box(gpa, .{ 1, 1, 1 })),
        };
        self.scene.setTier(self.tier);
        return self;
    }

    fn mesh(gpa: std.mem.Allocator, gfx: *three.Gfx3D, made: anytype) three.MeshId {
        var s = made catch @panic("OOM");
        defer s.deinit(gpa);
        var d = s.desc();
        d.keep_cpu = true; // triangle picking
        return gfx.createMesh(d) catch @panic("mesh");
    }

    pub fn deinit(self: *Demo, cx: *App) void {
        self.focus.release(cx);
        self.scene.deinit();
        self.gfx.deinit();
        self.gpa.destroy(self.scene);
        self.gpa.destroy(self.gfx);
    }

    /// Rebuild the draw list for the current time and settings.
    fn buildScene(self: *Demo) void {
        const s = self.scene;
        s.clearDraws();
        s.camera = self.orbit.camera();
        s.clear = .{ 0, 0, 0, 0 }; // the UI panel shows through
        s.sun = .{
            .direction = three.Sun.fromAngles(-145, 50),
            .color = .{ 1, 0.94, 0.85 },
            .intensity = 2.4,
            .shadow = .{ .enabled = self.tier != .low, .softness = 2 },
        };
        s.hemisphere = .{ .sky = .{ 0.95, 0.95, 0.92 }, .ground = .{ 0.3, 0.24, 0.18 }, .intensity = 0.9 };
        s.post.exposure = 0.95;

        const shading: three.Shading = if (self.toon) .toon else .pbr;
        const outline: ?three.Outline = if (self.toon) .{ .width = 0.02, .color = .{ 0.02, 0.012, 0.01, 1 } } else null;

        // Wooden slab (table).
        s.draw(self.slab, M.translation(.new(0, -0.15, 0)).mul(M.scaling(.new(grid + 1.2, 0.3, grid + 1.2))), .{ .material = .{
            .shading = shading,
            .base_color = three.rgb(0x8a6238),
            .roughness = 0.7,
            .detail = .{ .scale = 3, .amount = 0.12 },
        } }) catch return;

        var instances: [grid * grid]three.Instance = undefined;
        for (0..grid) |i| for (0..grid) |j| {
            const k = i * grid + j;
            const x = @as(f32, @floatFromInt(i)) - (grid - 1) / 2.0;
            const z = @as(f32, @floatFromInt(j)) - (grid - 1) / 2.0;
            const phase = @as(f32, @floatFromInt(i + j)) * 0.45;
            const h = 0.35 + 0.25 * (0.5 + 0.5 * @sin(self.time * 1.6 + phase));
            const hue = @as(f32, @floatFromInt(k % 7)) / 7.0;
            const pick_id: u32 = @intCast(k + 1);
            var tint = hueColor(hue);
            if (pick_id == self.hovered) tint = .{ 1, 0.95, 0.6, 1 };
            instances[k] = .{
                .model = M.translation(.new(x, h / 2, z)).mul(M.rotationY(phase * 0.2)).mul(M.scaling(.new(0.62, h, 0.62))),
                .tint = tint,
                .pick_id = pick_id,
            };
        };
        s.drawInstanced(self.box, &instances, .{ .material = .{ .shading = shading, .roughness = 0.55, .outline = outline } }) catch return;

        const balls = [_]struct { p: V, c: u24, metal: f32 }{
            .{ .p = .new(-3.1, 1.25, -2.4), .c = 0xd0261c, .metal = 0 },
            .{ .p = .new(2.6, 1.35, 1.9), .c = 0xe8c56a, .metal = 1 },
            .{ .p = .new(0.4, 1.45, -3.3), .c = 0x2650c0, .metal = 0 },
        };
        for (balls, 0..) |b, bi| {
            const bob = 0.15 * @sin(self.time * 2 + @as(f32, @floatFromInt(bi)));
            s.draw(self.sphere, M.translation(b.p.add(.new(0, bob, 0))).mul(M.scaling(.splat(0.8))), .{ .material = .{
                .shading = shading,
                .base_color = three.rgb(b.c),
                .metallic = b.metal,
                .roughness = 0.3,
                .outline = outline,
            } }) catch return;
        }
    }

    fn hueColor(h: f32) [4]f32 {
        const r = std.math.clamp(@abs(h * 6 - 3) - 1, 0, 1);
        const g = std.math.clamp(2 - @abs(h * 6 - 2), 0, 1);
        const b = std.math.clamp(2 - @abs(h * 6 - 4), 0, 1);
        return .{ 0.25 + 0.6 * r, 0.25 + 0.6 * g, 0.25 + 0.6 * b, 1 };
    }

    // -- input ----------------------------------------------------------------

    fn onDown(self: *Demo, ev: *const input.MouseDownEvent, _: *Window, cx: *Context(Demo)) void {
        self.drag_from = ev.position;
        cx.notify();
    }

    fn onUp(self: *Demo, _: *const input.MouseUpEvent, _: *Window, cx: *Context(Demo)) void {
        self.drag_from = null;
        cx.notify();
    }

    fn onMove(self: *Demo, ev: *const input.MouseMoveEvent, _: *Window, cx: *Context(Demo)) void {
        if (self.drag_from) |from| {
            if (ev.pressed_button == null) {
                self.drag_from = null;
            } else {
                self.orbit.rotate(ev.position.x - from.x, ev.position.y - from.y, 0.008);
                self.drag_from = ev.position;
            }
        }
        const hit = self.scene.pickAt(.{ ev.position.x, ev.position.y });
        self.hovered = if (hit) |h| h.pick_id else 0;
        cx.notify();
    }

    fn onScroll(self: *Demo, ev: *const input.ScrollWheelEvent, _: *Window, cx: *Context(Demo)) void {
        const dy: f32 = switch (ev.delta) {
            .pixels => |p| p.y / 50,
            .lines => |l| l.y,
        };
        self.orbit.zoom(std.math.pow(f32, 0.9, dy));
        cx.notify();
    }

    fn onKey(self: *Demo, ev: *const input.KeyDownEvent, _: *Window, cx: *Context(Demo)) void {
        const k = ev.keystroke.key;
        if (std.mem.eql(u8, k, "t")) self.toon = !self.toon;
        if (std.mem.eql(u8, k, "space")) self.animate = !self.animate;
        if (std.mem.eql(u8, k, "1")) self.setTier(.low);
        if (std.mem.eql(u8, k, "2")) self.setTier(.medium);
        if (std.mem.eql(u8, k, "3")) self.setTier(.high);
        cx.notify();
    }

    fn setTier(self: *Demo, tier: three.Tier) void {
        self.tier = tier;
        self.scene.setTier(tier);
        if (tier == .high) self.scene.post.tilt_shift = .{ .focus = 0.55, .range = 0.35, .blur = 3 };
    }

    fn onToggleToon(self: *Demo, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Demo)) void {
        self.toon = !self.toon;
        cx.notify();
    }

    fn onCycleTier(self: *Demo, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Demo)) void {
        self.setTier(switch (self.tier) {
            .low => .medium,
            .medium => .high,
            .high => .low,
        });
        cx.notify();
    }

    fn button(id: []const u8, label: []const u8, on: bool) zpui.StatefulDiv {
        return div().id(id).px(px(12)).py(px(6)).roundedLg().textSm().cursorPointer()
            .bg(if (on) theme.accent.opacity(0.25) else theme.panel)
            .border1().borderColor(if (on) theme.accent else theme.border)
            .textColor(if (on) theme.accent else theme.text)
            .child(label);
    }

    pub fn render(self: *Demo, window: *Window, cx: *Context(Demo)) zpui.Div {
        const now = cx.app.executor.now();
        if (self.last_ns != 0 and self.animate) {
            const dt = @as(f32, @floatFromInt(now -| self.last_ns)) / 1e9;
            self.time += @min(dt, 0.1);
        }
        self.last_ns = now;
        self.frames += 1;
        self.buildScene();
        if (self.animate) window.requestAnimationFrame();

        const st = self.scene.stats;
        const stats = zpui.fmt("{d} draws · {d} instances · {d}k tris · gpu {d:.2} ms{s}", .{
            st.draws, st.instances, st.triangles / 1000, st.gpu_ms, if (st.cached) " · cached" else "",
        });
        const hover_text = if (self.hovered != 0)
            zpui.fmt("box #{d} (row {d}, col {d})", .{ self.hovered, (self.hovered - 1) / grid + 1, (self.hovered - 1) % grid + 1 })
        else
            "hover a box";

        return div()
            .trackFocus(self.focus)
            .onKeyDown(cx.listener(Demo.onKey))
            .sizeFull().flex().flexCol().bg(theme.bg).fontFamily("Geist").textColor(theme.text)
            .child(div().flexNone().h(px(52)).px(px(18)).flex().itemsCenter().justifyBetween()
                .borderB1().borderColor(theme.border)
                .child(div().flex().itemsCenter().gap(px(10))
                    .child(div().textBase().fontWeight(600).child("zpui.three"))
                    .child(div().textXs().textColor(theme.muted).child(stats)))
                .child(div().flex().gap(px(8))
                    .child(button("toon", if (self.toon) "Toon: on (T)" else "Toon: off (T)", self.toon).onClick(cx.listener(Demo.onToggleToon)))
                    .child(button("tier", switch (self.tier) {
                        .low => "Tier: low (1/2/3)",
                        .medium => "Tier: medium (1/2/3)",
                        .high => "Tier: high (1/2/3)",
                    }, self.tier == .high).onClick(cx.listener(Demo.onCycleTier)))))
            .child(div().id("viewport").relative().flex1().m(px(14)).roundedXl()
                .bg(color_grad())
                .onMouseDown(.left, cx.listener(Demo.onDown))
                .onMouseUp(.left, cx.listener(Demo.onUp))
                .onMouseMove(cx.listener(Demo.onMove))
                .onScrollWheel(cx.listener(Demo.onScroll))
                .child(zpui.viewport3dRounded(self.scene, 12).absolute().inset0())
                // 2D over 3D: frosted HUD (backdrop blur of the 3D image).
                .child(div().absolute().left(px(16)).bottom(px(16))
                    .child(zpui.frosted(14, 14, div()
                        .px(px(14)).py(px(10)).roundedXl().bg(hex(0xffffff).opacity(0.14))
                        .border1().borderColor(hex(0xffffff).opacity(0.22))
                        .flex().flexCol().gap(px(2))
                        .child(div().textSm().fontWeight(600).child(hover_text))
                        .child(div().textXs().textColor(hex(0xf2ece4).opacity(0.75)).child("drag to orbit · scroll to zoom · space pauses"))))));
    }

    fn color_grad() zpui.Background {
        return zpui.color.linearGradient(180, .{ .color = hex(0x2a231d), .percentage = 0 }, .{ .color = hex(0x15110e), .percentage = 1 });
    }
};

const Launch = struct { max_frames: ?u64 };

fn onLaunch(launch: *Launch, app: *App) void {
    app.quit_when_last_window_closes = true;
    for ([_]assets.Font{ .geist_regular, .geist_medium, .geist_semi_bold, .geist_bold }) |f|
        app.addFont(f.info().data) catch |err| log.err("addFont: {t}", .{err});
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 60, .y = 60 }, .size = .{ .width = 1180, .height = 780 } },
        .titlebar = .{ .title = "zpui.three demo" },
        .app_id = "dev.zpui.three-demo",
    }, Demo, Demo.init, .{}) catch |err| {
        log.err("openWindow failed: {t}", .{err});
        app.quit();
        return;
    };
    if (launch.max_frames) |n| {
        const Quit = struct {
            left: u64,
            fn tick(self: *const @This(), win: *Window, a: *App) void {
                if (self.left == 0) a.quit() else win.onNextFrame(@This(){ .left = self.left - 1 }, tick);
            }
        };
        handle.window(app).?.onNextFrame(Quit{ .left = n }, Quit.tick);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var launch: Launch = .{ .max_frames = null };
    var backend_name: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--frames") and i + 1 < argv.len) {
            i += 1;
            launch.max_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, argv[i], "--backend") and i + 1 < argv.len) {
            i += 1;
            backend_name = argv[i];
        }
    }
    const plat = switch (builtin.os.tag) {
        .linux => try zpui.linux_platform.create(gpa, .{
            .io = init.io,
            .backend = if (backend_name) |n| std.meta.stringToEnum(zpui.linux_platform.BackendKind, n) else null,
        }),
        .macos => try zpui.mac_platform.create(gpa),
        else => @compileError("three_demo: Linux or macOS only"),
    };
    const app = try App.init(gpa, plat);
    defer app.deinit();
    app.run(&launch, onLaunch);
}
