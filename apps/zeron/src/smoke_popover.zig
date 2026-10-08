//! `ZERON_SMOKE_POPOVER=model|project|tooltip` (macOS, with `--smoke-frames N`): after
//! the frames, open the model picker, the new-session project picker, or hover the
//! sidebar's Settings button for its tooltip, wait until the native popover container
//! is shown (`zpui.nativePopover` / native tooltips), let it settle, then capture:
//!   * `<out>`: the screen area around the main window and the popover (the popover
//!     may extend past the window; its shadow and glass are WindowServer output);
//!   * `<out stem>-popover.png`: the popover window alone (with its shadow).
//! `FAIL: zeron smoke: native popover ...` when no popover window appears (the Native
//! menus setting off, or the platform kept the in-window fallback).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const smoke = @import("smoke.zig");
const shell_mod = @import("ui/shell/shell.zig");
const pickers_mod = @import("ui/pickers/root.zig");
const composer_mod = @import("zeron_composer");
const shell_actions = @import("zeron_actions").shell;

const App = zpui.App;
const Window = zpui.Window;

pub const Kind = enum { model, project, tooltip };
/// Called once with the result (the caller quits).
pub const Done = *const fn (app: *App, ok: bool) void;

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: []const u8,
    kind: Kind,
    done: Done,
};

var ctx: ?Ctx = null;

pub fn begin(gpa: std.mem.Allocator, io: std.Io, out: []const u8, win: *Window, app: *App, kind_name: []const u8, done: Done) void {
    const kind = std.meta.stringToEnum(Kind, kind_name) orelse return fail(app, done, "unknown ZERON_SMOKE_POPOVER (model, project, tooltip)");
    if (builtin.os.tag != .macos) return fail(app, done, "native popover captures are macOS only");
    ctx = .{ .gpa = gpa, .io = io, .out = out, .kind = kind, .done = done };
    std.debug.print("zeron smoke: native popover: {t} (native popovers {s})\n", .{ kind, if (win.nativePopoversAvailable()) "available" else "unavailable" });
    // The captures should show the app frontmost (main window active, coloured traffic
    // lights), as when someone clicks the picker.
    activate(win);
    _ = logWindowState(win, "before");
    switch (kind) {
        // The project chip is on the new-session canvas.
        .project => win.dispatchAction(shell_actions.NewSession{}),
        // The hover target is found through the accessibility tree.
        .tooltip => win.setA11yActive(true),
        .model => {},
    }
    win.refresh();
    win.onNextFrame(Step{ .phase = .prepare, .left = 30 }, Step.tick);
}

fn fail(app: *App, done: Done, reason: []const u8) void {
    std.debug.print("FAIL: zeron smoke: native popover: {s}\n", .{reason});
    done(app, false);
}

const Step = struct {
    phase: enum { prepare, wait, settle },
    left: u32,

    fn tick(self: *const Step, win: *Window, app: *App) void {
        const c = &(ctx orelse return);
        var next = self.*;
        win.refresh();
        switch (next.phase) {
            .prepare => if (next.left == 0) {
                act(c, win, app) catch |err| return fail(app, c.done, @errorName(err));
                next = .{ .phase = .wait, .left = 300 };
            } else {
                next.left -= 1;
            },
            .wait => if (visiblePopover(win) != null) {
                next = .{ .phase = .settle, .left = 30 };
            } else if (next.left == 0) {
                return fail(app, c.done, "no native popover window was shown");
            } else {
                next.left -= 1;
            },
            .settle => if (next.left == 0) {
                if (!logWindowState(win, "open")) return fail(app, c.done, "the main window lost main status to the popover");
                const ok = if (capture(c, win)) true else |err| blk: {
                    std.debug.print("FAIL: zeron smoke: native popover capture: {t}\n", .{err});
                    break :blk false;
                };
                return c.done(app, ok);
            } else {
                next.left -= 1;
            },
        }
        win.onNextFrame(next, tick);
    }
};

fn act(c: *const Ctx, win: *Window, app: *App) !void {
    const root = win.root orelse return error.NoRootView;
    const shell = root.entity.downcast(shell_mod.Shell) orelse return error.RootIsNotTheShell;
    const slots = &shell.read(app).main.read(app).slots;
    switch (c.kind) {
        .model => slots.composer_view.update(app, composer_mod.ComposerView.toggleModelPicker, .{win}),
        .project => slots.pickers.update(app, pickers_mod.Pickers.toggle, .{ .space, win }),
        .tooltip => {
            const tree = &win.rendered_frame.a11y;
            const target = for (tree.nodes.items) |n| {
                const label = tree.str(n.label) orelse continue;
                if (std.mem.eql(u8, label, "Settings") and n.bounds.size.width > 0) break n.bounds;
            } else return error.NoSettingsButtonInTheAccessibilityTree;
            const p: zpui.Point(f32) = .{ .x = target.origin.x + target.size.width / 2, .y = target.origin.y + target.size.height / 2 };
            std.debug.print("zeron smoke: hovering the Settings button at ({d:.0}, {d:.0})\n", .{ p.x, p.y });
            _ = win.dispatchEvent(.{ .mouse_move = .{ .position = p } });
        },
    }
}

/// Bring the app and its main window to the front (macOS).
fn activate(win: *Window) void {
    if (builtin.os.tag != .macos) return;
    const mac = zpui.mac_platform;
    const ak = mac.appkit;
    const nsapp = ak.sharedApp();
    const objc = mac.objc_runtime;
    if (nsapp.msg(objc.BOOL, "respondsToSelector:", .{objc.cachedSel("activate")}) == objc.YES) nsapp.msg(void, "activate", .{});
    nsapp.msg(void, "activateIgnoringOtherApps:", .{objc.YES});
    mac.MacWindow.fromWindow(win.platform_window).native_window.msg(void, "makeKeyAndOrderFront:", .{@as(?objc.id, null)});
}

/// Log `[NSApp mainWindow]` / `keyWindow` (main window, popover, other, none) and
/// whether the app is active. False when a popover is main (the parent lost main).
fn logWindowState(win: *Window, comptime when: []const u8) bool {
    if (builtin.os.tag != .macos) return true;
    const mac = zpui.mac_platform;
    const objc = mac.objc_runtime;
    const nsapp = mac.appkit.sharedApp();
    const main_ns = mac.MacWindow.fromWindow(win.platform_window).native_window;
    const pop_ns: ?objc.id = if (visiblePopover(win)) |pw| mac.MacWindow.fromWindow(pw.platform_window).native_window else null;
    const Name = struct {
        fn of(w: ?objc.id, m: objc.id, p: ?objc.id) []const u8 {
            const x = w orelse return "none";
            if (x == m) return "main window";
            if (p != null and x == p.?) return "popover";
            return "other";
        }
    };
    const main_w = nsapp.msg(?objc.id, "mainWindow", .{});
    const key_w = nsapp.msg(?objc.id, "keyWindow", .{});
    const active = nsapp.msg(objc.BOOL, "isActive", .{}) == objc.YES;
    std.debug.print("zeron smoke: window state ({s}): app active={} NSApp.mainWindow={s} NSApp.keyWindow={s} parent isMainWindow={}\n", .{
        when, active, Name.of(main_w, main_ns, pop_ns), Name.of(key_w, main_ns, pop_ns), main_ns.msg(objc.BOOL, "isMainWindow", .{}) == objc.YES,
    });
    return !(pop_ns != null and main_w != null and main_w.? == pop_ns.?);
}

/// The parent's shown popover window, if any.
fn visiblePopover(win: *Window) ?*Window {
    for (win.native_popovers.entries.items) |e| {
        if (!e.placed_visible or e.closing) continue;
        const id = e.window orelse continue;
        return win.app.windowById(id) orelse continue;
    }
    return null;
}

fn capture(c: *const Ctx, win: *Window) !void {
    if (builtin.os.tag != .macos) return error.MacOnly;
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const pw = visiblePopover(win) orelse return error.PopoverClosedBeforeCapture;
    const mw = mac.MacWindow.fromWindow(win.platform_window);
    const pmw = mac.MacWindow.fromWindow(pw.platform_window);
    const a = mac.glass_debug.windowRectCG(mw);
    const b = mac.glass_debug.windowRectCG(pmw);
    const margin: f64 = 32; // the popover's shadow
    const x0 = @min(a.origin.x, b.origin.x - margin);
    const y0 = @min(a.origin.y, b.origin.y - margin);
    const x1 = @max(a.origin.x + a.size.width, b.origin.x + b.size.width + margin);
    const y1 = @max(a.origin.y + a.size.height, b.origin.y + b.size.height + margin);
    const rect: cf.CGRect = .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = x1 - x0, .height = y1 - y0 } };
    const e = for (win.native_popovers.entries.items) |e| {
        if (e.window != null and e.window.? == pw.id) break e;
    } else return error.PopoverEntryGone;
    std.debug.print("zeron smoke: native popover {t}: frame {d:.0}x{d:.0} at ({d:.0}, {d:.0}) in the window, edge {t}, material {t}, liquid glass {}, key {}\n", .{
        c.kind,             e.frame.?.size.width,   e.frame.?.size.height, e.frame.?.origin.x, e.frame.?.origin.y, e.edge,
        e.options.material, e.options.liquid_glass, e.options.key,
    });

    const composite = try smoke.captureMacImage(c.gpa, rect, cf.kCGWindowListOptionOnScreenOnly, cf.kCGNullWindowID, cf.kCGWindowImageBestResolution);
    defer c.gpa.free(composite.pixels);
    try write(c, c.out, composite);
    const st = smoke.stats(composite.pixels);
    std.debug.print("zeron smoke: {d:.2}% of pixels differ from the corner color, {d} distinct colors (quantized)\n", .{ st.differing * 100, st.distinct });
    if (st.differing < 0.01 or st.distinct < 8) return error.BlankFrame;

    const stem = if (std.mem.endsWith(u8, c.out, ".png")) c.out[0 .. c.out.len - 4] else c.out;
    var buf: [512]u8 = undefined;
    const alone_path = try std.fmt.bufPrint(&buf, "{s}-popover.png", .{stem});
    const alone = smoke.captureMacImage(c.gpa, cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, pmw.windowNumber(), cf.kCGWindowImageBestResolution) catch |err| {
        std.debug.print("zeron smoke: popover window capture: {t}\n", .{err});
        return;
    };
    defer c.gpa.free(alone.pixels);
    try write(c, alone_path, alone);
}

fn write(c: *const Ctx, path: []const u8, img: smoke.Image) !void {
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(c.io, dir) catch {};
    const encoded = try smoke.encodePng(c.gpa, img.width, img.height, img.pixels);
    defer c.gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = encoded });
    std.debug.print("zeron smoke: wrote {s} ({d}x{d})\n", .{ path, img.width, img.height });
}

test {
    // Compile the probe on every host (its capture is macOS-only at run time).
    std.testing.refAllDecls(@This());
    _ = &act;
    _ = &capture;
    _ = &Step.tick;
}
