//! Real-app smoke test (CI): `zeron --smoke-frames N` (or `ZERON_SMOKE_FRAMES=N`).
//!
//! After the main window has presented N frames, captures it and exits:
//!   macOS: the on-screen window via `CGWindowListCreateImage` (compositor
//!          output, the same path `examples/mac_window.zig` uses in CI);
//!   Linux: the window's rectangle of the X11 root via ImageMagick
//!          `import -window root … ppm:-` (CI runs under Xvfb; needs X11).
//! and writes `zig-out/zeron-<os>.png` (`zig-out/zeron-<os>-light.png` for the
//! light appearance; `ZERON_SMOKE_OUT=<path>` overrides). Exit status 0 on
//! success, 1 after a `FAIL: <reason>` line when frames never arrive within
//! the watchdog timeout, the capture fails, or the image is blank (one flat
//! color = nothing rendered).
//!
//! `ZERON_SMOKE_BROWSER_URL=<http(s) url>` (needs a selected chat, e.g. fixture mode):
//! after the N frames, open a Browser tab in the right pane on that URL, wait until
//! the page reports loaded (FAIL on a load error or after ~20 s), let it paint, then
//! capture as above. Exercises the native web view (WKWebView child view on macOS,
//! the WebKitGTK helper's offscreen frames on Linux).
//!
//! `ZERON_SMOKE_MENU=1`: frosted-menu blur check, after the frames (and the browser
//! page, when combined with `ZERON_SMOKE_BROWSER_URL`). Shows high-contrast stripes
//! (`ui/shell/smoke_probe.zig`), captures, then opens a frosted floating card (the
//! real menu chrome, deferred like every menu) over them and captures again. Under
//! the card the stripes' high-frequency energy must drop to < 25% of the bare value
//! (a working backdrop blur flattens them; a blur sampling the wrong plane leaves
//! them crisp behind the tint), else `FAIL: zeron smoke: frosted menu is not blurred`.
//! Writes `<out stem>-menu-off.png` / `-menu.png`. With a browser tab open the card
//! sits on the macOS overlay plane above the WKWebView (the regression's path): the
//! check then also reads the overlay plane back and requires the blurred backdrop
//! there to be opaque (it was transparent when the blur sampled its own plane).
//! When the GPU has no MetalPerformanceShaders (blurs draw unblurred), the energy
//! check is skipped with a `SKIP:` line; the overlay-plane check still runs.
//!
//! `ZERON_SMOKE_SETTINGS=<section>` (`general`, `appearance`, ...): after the frames,
//! open Settings on that page, render 30 more frames and capture it (on macOS the
//! page's switches, pop-ups and sliders are native AppKit controls).
//!
//! `ZERON_SMOKE_SHORTCUTS=1`: the menu bar and every app shortcut through real AppKit
//! key events and menu picks, ending with ⌘Q (smoke_shortcuts.zig).
//!
//! `ZERON_SMOKE_SETTINGS_STRESS=<cycles>`: after the frames, open Settings, visit every
//! section and poke every visible native control (macOS: real `NSEvent` clicks through
//! AppKit's tracking loop for switches / checkboxes / sliders / steppers, pop-up menus
//! opened and cancelled, programmatic `sendAction:` for the rest), close Settings,
//! wait a varying number of frames (sometimes past the controls' idle detach), and
//! repeat. Every step is logged (`zeron smoke: stress ...`) so a crash names the last
//! action. Exits 0 after `PASS: zeron smoke: settings stress` (no capture).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");

const App = zpui.App;
const Window = zpui.Window;

pub const Options = struct {
    frames: u64,
    light: bool,
    /// Output path override (else `zig-out/zeron-<os>[-light].png`).
    out: ?[]const u8 = null,
    /// Watchdog: fail if the capture has not happened by then.
    timeout_s: i64 = 90,
    /// Open a Browser tab on this URL before capturing (ZERON_SMOKE_BROWSER_URL).
    browser_url: ?[]const u8 = null,
    /// [glass-lab] ZERON_SMOKE_DIAG=1 (macOS): also print the glass diagnostics and write
    /// `<out>-metal-{main,overlay,top}.png` (what zpui's Metal planes presented),
    /// `<out>-onscreen.png` (the display in the window's rect) and
    /// `<out>-screencapture.png` (`screencapture -x`) next to the window capture.
    diag: bool = false,
    /// ZERON_SMOKE_MENU=1: the frosted-menu blur check (see the file comment).
    menu: bool = false,
    /// ZERON_SMOKE_SETTINGS=<section> (e.g. `appearance`): open Settings on that page
    /// before capturing (shows the native AppKit controls on macOS).
    settings: ?[]const u8 = null,
    /// ZERON_SMOKE_SETTINGS_STRESS=<cycles>: the Settings open/poke/close stress.
    settings_stress: ?[]const u8 = null,
    /// ZERON_SMOKE_SHORTCUTS=1: real key events and menu picks (smoke_shortcuts.zig).
    shortcuts: bool = false,
};

const shell_mod = @import("ui/shell/shell.zig");
const right_pane_mod = @import("ui/shell/right_pane.zig");
const browser = @import("ui/browser/root.zig");
const smoke_probe = @import("ui/shell/smoke_probe.zig");

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    done: std.atomic.Value(bool) = .init(false),
    exit_code: u8 = 0,
};

var state: ?State = null;

/// Arm the smoke test for `win` (call once, right after opening the window).
pub fn start(gpa: std.mem.Allocator, io: std.Io, win: *Window, opts: Options) void {
    state = .{ .gpa = gpa, .io = io, .opts = opts };
    if (opts.settings_stress != null) state.?.opts.timeout_s = 3000;
    std.debug.print("zeron smoke: rendering {d} frames, then capturing (watchdog {d}s)\n", .{ opts.frames, opts.timeout_s });
    if (std.Thread.spawn(.{}, watchdog, .{ io, state.?.opts.timeout_s, opts.frames })) |t| t.detach() else |err| std.debug.print("WARN: smoke watchdog thread: {t}\n", .{err});
    win.onNextFrame(Tick{ .left = opts.frames }, Tick.tick);
}

/// Exit code for `main` after `App.run` returns (0 when the smoke test is off).
pub fn exitCode() u8 {
    const s = &(state orelse return 0);
    if (!s.done.load(.acquire)) {
        std.debug.print("FAIL: zeron smoke: the app quit before {d} frames were rendered\n", .{s.opts.frames});
        return 1;
    }
    return s.exit_code;
}

var frames_seen: std.atomic.Value(u64) = .init(0);

const Tick = struct {
    left: u64,
    /// [glass-lab] Frames waited for the Metal readback (diag); 0 = not armed yet.
    waited: u32 = 0,
    fn tick(self: *const Tick, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        if (self.left > 0) return win.onNextFrame(Tick{ .left = self.left - 1 }, tick);
        const s = &state.?;
        if (s.opts.settings_stress) |n| if (self.waited == 0) return SettingsStress.begin(s, win, app, n);
        if (s.opts.shortcuts and self.waited == 0) return smoke_shortcuts.begin(win, app, shortcutsDone);
        if (s.opts.settings) |section| if (self.waited == 0) return openSettings(s, win, app, section);
        if (s.opts.browser_url) |url| return openBrowser(s, win, app, url);
        if (s.opts.menu and self.waited == 0) return MenuProbe.begin(s, win, app);
        if (builtin.os.tag == .macos and s.opts.diag) {
            // Arm a readback of the next presented frame's planes, then wait for it.
            const mw = zpui.mac_platform.MacWindow.fromWindow(win.platform_window);
            if (self.waited == 0) mw.renderer.armLayerCapture();
            if (mw.renderer.layer_captures[0] == null and self.waited < 20) {
                win.refresh();
                return win.onNextFrame(Tick{ .left = 0, .waited = self.waited + 1 }, tick);
            }
            mw.renderer.disarmLayerCapture();
        }
        finish(s, win, app);
    }

    fn finish(s: *State, win: *Window, app: *App) void {
        s.exit_code = if (capture(s, win)) 0 else |err| blk: {
            std.debug.print("FAIL: zeron smoke: {t}\n", .{err});
            break :blk 1;
        };
        s.done.store(true, .release);
        app.quit();
    }
};

const settings_ui = @import("ui/settings/root.zig");
const smoke_shortcuts = @import("smoke_shortcuts.zig");

fn shortcutsDone(_: *Window, _: *App, r: smoke_shortcuts.Result) void {
    const s = &state.?;
    if (r.failures == 0) {
        std.debug.print("PASS: zeron smoke: shortcuts ({d} checks)\n", .{r.passes});
        s.exit_code = 0;
    } else {
        std.debug.print("FAIL: zeron smoke: shortcuts: {d} of {d} checks failed\n", .{ r.failures, r.failures + r.passes });
        s.exit_code = 1;
    }
    s.done.store(true, .release);
}

/// ZERON_SMOKE_SETTINGS: open Settings on `section`, let it settle, then capture.
fn openSettings(s: *State, win: *Window, app: *App, section: []const u8) void {
    const root = win.root orelse return failNow(s, app, "no root view");
    const shell = root.entity.downcast(shell_mod.Shell) orelse return failNow(s, app, "root view is not the shell");
    const which = std.meta.stringToEnum(settings_ui.view.Section, section) orelse return failNow(s, app, "unknown ZERON_SMOKE_SETTINGS section");
    shell.update(app, shell_mod.Shell.openSettings, .{win});
    const v = shell.read(app).settings_view orelse return failNow(s, app, "settings did not open");
    v.update(app, settings_ui.SettingsView.openSection, .{which});
    std.debug.print("zeron smoke: Settings → {s}\n", .{section});
    win.onNextFrame(SettingsWait{ .left = 30 }, SettingsWait.tick);
}

const SettingsWait = struct {
    left: u64,
    fn tick(self: *const SettingsWait, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        const s = &state.?;
        if (self.left == 0) return Tick.finish(s, win, app);
        win.refresh();
        win.onNextFrame(SettingsWait{ .left = self.left - 1 }, tick);
    }
};

/// ZERON_SMOKE_SETTINGS_STRESS: open → every section (poke, poke again) → close, `cycles` times.
const SettingsStress = struct {
    cycles: u32,
    cycle: u32 = 0,
    section: usize = 0,
    step: Step = .open,
    wait: u32 = 0,
    pokes: u64 = 0,
    ax_nodes: u64 = 0,

    const Step = enum { open, visit, poke, unpoke, close };
    const sections = settings_ui.view.Section.all;

    fn begin(s: *State, win: *Window, app: *App, arg: []const u8) void {
        const n = std.fmt.parseInt(u32, arg, 10) catch return failNow(s, app, "ZERON_SMOKE_SETTINGS_STRESS wants a cycle count");
        std.debug.print("zeron smoke: stress: {d} Settings cycles over {d} sections\n", .{ n, sections.len });
        if (builtin.os.tag == .macos) mac_poke.activate(win);
        win.onNextFrame(SettingsStress{ .cycles = n }, tick);
    }

    fn tick(self: *const SettingsStress, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        const s = &state.?;
        var next = self.*;
        win.refresh();
        // Like an accessibility client (window managers, launchers, password managers
        // on real Macs): walk the window's AX tree between frames.
        const seed = next.cycle *% 131 +% next.wait +% @as(u32, @truncate(next.pokes)) +% @as(u32, @truncate(next.ax_nodes));
        if (builtin.os.tag == .macos) next.ax_nodes +%= mac_poke.axWalk(win, seed);
        // Like a user moving the mouse and scrolling the page: the controls move, clip
        // and hide under the pointer every frame.
        if (MenuProbe.shellOf(win, app)) |sh| if (sh.read(app).settings_view) |v| {
            var prng = std.Random.DefaultPrng.init(seed);
            const rng = prng.random();
            if (rng.uintLessThan(u8, 3) == 0) {
                var l = v.lease(app);
                l.value.page_scroll.setOffset(.{ .x = 0, .y = -rng.float(f32) * 1500 });
                l.cx.notify();
                l.end();
            }
            if (builtin.os.tag == .macos) mac_poke.moveMouse(win, rng);
        };
        if (builtin.os.tag == .macos and next.step == .visit and next.cycle % 7 == 6 and next.section % 3 == 0) mac_poke.resize(win, next.section);
        if (next.wait > 0) {
            next.wait -= 1;
            return win.onNextFrame(next, tick);
        }
        const shell = MenuProbe.shellOf(win, app) orelse return failNow(s, app, "stress: root view is not the shell");
        switch (next.step) {
            .open => {
                std.debug.print("zeron smoke: stress: cycle {d}: open Settings\n", .{next.cycle});
                shell.update(app, shell_mod.Shell.openSettings, .{win});
                if (shell.read(app).settings_view == null) return failNow(s, app, "stress: settings did not open");
                next.section = (next.cycle * 3) % sections.len; // vary the landing page
                next.step = .visit;
                next.wait = next.cycle % 3;
            },
            .visit => {
                const v = shell.read(app).settings_view orelse return failNow(s, app, "stress: settings closed under us");
                const which = sections[next.section % sections.len];
                std.debug.print("zeron smoke: stress: cycle {d}: section {t}\n", .{ next.cycle, which });
                v.update(app, settings_ui.SettingsView.openSection, .{which});
                next.step = .poke;
                next.wait = 2 + next.cycle % 2;
                // Every 3rd cycle lingers on its first page past the idle detach of the
                // chrome Settings hides (titlebar glass group, sidebar controls).
                if (next.cycle % 3 == 1 and next.section == (next.cycle * 3) % sections.len) {
                    std.debug.print("zeron smoke: stress: cycle {d}: linger in Settings\n", .{next.cycle});
                    next.wait = zpui.window.native_controls_mod.keep_idle_presents + 30;
                }
            },
            .poke, .unpoke => {
                next.pokes += poke(win, next.cycle, next.section, next.step == .unpoke);
                if (next.step == .poke) {
                    next.step = .unpoke;
                    // Sometimes leave the page (or Settings) while the clicks are still queued.
                    next.wait = if (next.cycle % 4 == 3) 0 else 2;
                } else {
                    next.section += 1;
                    const visited = next.section - (next.cycle * 3) % sections.len;
                    next.step = if (visited >= sections.len) .close else .visit;
                    next.wait = if (next.cycle % 4 == 3) 0 else 1;
                }
            },
            .close => {
                std.debug.print("zeron smoke: stress: cycle {d}: close Settings\n", .{next.cycle});
                shell.update(app, shell_mod.Shell.closeSettings, .{win});
                next.cycle += 1;
                if (next.cycle >= next.cycles) {
                    std.debug.print("PASS: zeron smoke: settings stress ({d} cycles, {d} control pokes, {d} control events, {d} attaches, {d} AX nodes read)\n", .{ next.cycles, next.pokes, controlEvents(win), win.native_controls.attach_count, next.ax_nodes });
                    s.done.store(true, .release);
                    s.exit_code = 0;
                    return app.quit();
                }
                next.step = .open;
                // Every 5th cycle stays closed past the controls' idle detach.
                next.wait = if (next.cycle % 5 == 0) zpui.window.native_controls_mod.keep_idle_presents + 10 else next.cycle % 4;
            },
        }
        win.onNextFrame(next, tick);
    }

    /// Native control events received (0 on app commits that predate the counter).
    fn controlEvents(win: *Window) u32 {
        if (comptime !@hasField(@TypeOf(win.native_controls), "event_count")) return 0;
        return win.native_controls.event_count;
    }

    /// Poke every native control placed in the last presented frame; returns the count.
    fn poke(win: *Window, cycle: u32, section: usize, again: bool) u64 {
        if (builtin.os.tag != .macos) return 0;
        return mac_poke.pokeAll(win, cycle *% 7919 +% @as(u32, @intCast(section)) *% 31 +% @intFromBool(again));
    }
};

const mac_poke = if (builtin.os.tag == .macos) struct {
    const mac = zpui.mac_platform;
    const objc = mac.objc_runtime;
    const ak = mac.appkit;
    const id = objc.id;
    const NSInteger = isize;
    const NSUInteger = usize;

    fn activate(win: *Window) void {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        ak.sharedApp().msg(void, "activateIgnoringOtherApps:", .{objc.YES});
        mw.native_window.msg(void, "makeKeyAndOrderFront:", .{@as(?id, null)});
    }

    const Target = struct { view: id, kind: zpui.platform.NativeControlKind, label: []const u8, center: ak.NSPoint, frame: ak.NSRect, min: f64, max: f64, items: usize };

    fn pokeAll(win: *Window, seed: u64) u64 {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        var targets: [64]Target = undefined;
        var n: usize = 0;
        for (win.native_controls.entries.items) |e| {
            if (n == targets.len) break;
            const c = for (mw.natives.children.items) |c| {
                if (c.id == e.view) break c;
            } else continue;
            if (c.last == null or c.region.size.width < 2 or c.region.size.height < 2) continue;
            const f = ak.frame(c.view);
            // Center of the visible part of the control (content-view coordinates).
            const x0 = @max(f.origin.x, c.region.origin.x);
            const x1 = @min(f.origin.x + f.size.width, c.region.origin.x + c.region.size.width);
            const y0 = @max(f.origin.y, c.region.origin.y);
            const y1 = @min(f.origin.y + f.size.height, c.region.origin.y + c.region.size.height);
            if (x1 - x0 < 2 or y1 - y0 < 2) continue;
            targets[n] = .{ .view = c.view, .kind = e.kind, .label = e.state.label, .center = .{ .x = (x0 + x1) / 2, .y = (y0 + y1) / 2 }, .frame = f, .min = e.state.min, .max = e.state.max, .items = e.state.items.len };
            n += 1;
        }
        for (targets[0..n]) |t| pokeOne(mw, t, rng);
        return n;
    }

    fn pokeOne(mw: *mac.MacWindow, t: Target, rng: std.Random) void {
        const mode = rng.uintLessThan(u8, 4);
        switch (t.kind) {
            .switch_, .checkbox => if (mode < 2) {
                log(t, "click (NSEvent)");
                postClick(mw, t.center, 0);
            } else {
                log(t, "sendAction");
                const on = t.view.msg(NSInteger, "state", .{});
                t.view.msg(void, "setState:", .{@as(NSInteger, if (on == 1) 0 else 1)});
                sendAction(t.view);
            },
            .slider => if (mode < 2) {
                log(t, "drag (NSEvent)");
                const x = t.frame.origin.x + 4 + rng.float(f64) * @max(t.frame.size.width - 8, 1);
                postClick(mw, .{ .x = x, .y = t.center.y }, 3);
            } else {
                log(t, "sendAction");
                t.view.msg(void, "setDoubleValue:", .{t.min + rng.float(f64) * (t.max - t.min)});
                sendAction(t.view);
            },
            .stepper => if (mode < 2) {
                log(t, "click (NSEvent)");
                postClick(mw, t.center, 0);
            } else {
                log(t, "sendAction");
                t.view.msg(void, "setDoubleValue:", .{t.min + rng.float(f64) * (t.max - t.min)});
                sendAction(t.view);
            },
            .segmented => if (t.items > 0) {
                log(t, "sendAction");
                t.view.msg(void, "setSelectedSegment:", .{@as(NSInteger, @intCast(rng.uintLessThan(usize, t.items)))});
                sendAction(t.view);
            },
            .popup => if (mode == 0) {
                // Open the menu with a real click; cancel it from the tracking run loop.
                log(t, "open menu (NSEvent), cancel in 0.3s");
                if (t.view.msg(?id, "menu", .{})) |menu| {
                    const modes = ak.class("NSArray").msg(id, "arrayWithObject:", .{ak.nsString("kCFRunLoopCommonModes")});
                    menu.msg(void, "performSelector:withObject:afterDelay:inModes:", .{ objc.sel("cancelTracking"), @as(?id, null), @as(f64, 0.3), modes });
                }
                postClick(mw, t.center, 0);
            } else if (t.items > 0) {
                const ix = rng.uintLessThan(usize, t.items);
                std.debug.print("zeron smoke: stress: popup \"{s}\": sendAction item {d}/{d}\n", .{ t.label, ix, t.items });
                t.view.msg(void, "selectItemAtIndex:", .{@as(NSInteger, @intCast(ix))});
                sendAction(t.view);
            },
        }
    }

    /// Walk the AX tree from the window (roles, labels, values, frames, parents) plus a
    /// hit test at a random point; returns the number of elements read.
    fn axWalk(win: *Window, seed: u64) u64 {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        var budget: u32 = 3000;
        visit(mw.native_window, 0, &budget);
        const f = ak.frame(mw.native_window);
        const p: ak.NSPoint = .{ .x = f.origin.x + rng.float(f64) * f.size.width, .y = f.origin.y + rng.float(f64) * f.size.height };
        if (mw.native_window.msg(?id, "accessibilityHitTest:", .{p})) |hit| visit(hit, 30, &budget);
        if (mw.native_window.msg(?id, "accessibilityFocusedUIElement", .{})) |foc| visit(foc, 30, &budget);
        return 3000 - budget;
    }

    fn responds(obj: id, comptime sel: [:0]const u8) bool {
        return objc.fromBOOL(obj.msg(objc.BOOL, "respondsToSelector:", .{objc.sel(sel)}));
    }

    fn visit(el: id, depth: u32, budget: *u32) void {
        if (budget.* == 0 or depth > 40) return;
        budget.* -= 1;
        inline for (.{ "accessibilityRole", "accessibilitySubrole", "accessibilityRoleDescription", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp", "accessibilityParent", "accessibilityWindow" }) |sel| {
            if (responds(el, sel)) _ = el.msg(?id, sel, .{});
        }
        if (responds(el, "accessibilityFrame")) _ = ak.msgStruct(ak.NSRect, el, "accessibilityFrame", .{});
        if (responds(el, "isAccessibilityElement")) _ = el.msg(objc.BOOL, "isAccessibilityElement", .{});
        if (!responds(el, "accessibilityChildren")) return;
        const kids = el.msg(?id, "accessibilityChildren", .{}) orelse return;
        const n = kids.msg(NSUInteger, "count", .{});
        var i: NSUInteger = 0;
        while (i < n) : (i += 1) visit(kids.msg(id, "objectAtIndex:", .{i}), depth + 1, budget);
    }

    /// Queue a mouse move to a random point of the window.
    fn moveMouse(win: *Window, rng: std.Random) void {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        const b = ak.bounds(mw.native_view);
        const p: ak.NSPoint = .{ .x = rng.float(f64) * b.size.width, .y = rng.float(f64) * b.size.height };
        const num = mw.native_window.msg(NSInteger, "windowNumber", .{});
        const now = ak.class("NSProcessInfo").msg(id, "processInfo", .{}).msg(f64, "systemUptime", .{});
        const ev = ak.class("NSEvent").msg(?id, "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            @as(NSUInteger, 5), p, @as(NSUInteger, 0), now, num, @as(?id, null), @as(NSInteger, 0), @as(NSInteger, 0), @as(f32, 0),
        }) orelse return;
        ak.sharedApp().msg(void, "postEvent:atStart:", .{ ev, objc.NO });
    }

    /// Resize the window (alternating sizes): live geometry changes under the controls.
    fn resize(win: *Window, k: usize) void {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        var f = ak.frame(mw.native_window);
        f.size.width = if (k % 2 == 0) 900 else 1280;
        f.size.height = if (k % 2 == 0) 640 else 820;
        std.debug.print("zeron smoke: stress: resize window to {d}x{d}\n", .{ f.size.width, f.size.height });
        mw.native_window.msg(void, "setFrame:display:", .{ f, objc.YES });
    }

    fn log(t: Target, what: []const u8) void {
        std.debug.print("zeron smoke: stress: {t} \"{s}\": {s}\n", .{ t.kind, t.label, what });
    }

    fn sendAction(view: id) void {
        const action = view.msg(?objc.SEL, "action", .{}) orelse return;
        _ = view.msg(objc.BOOL, "sendAction:to:", .{ action, view.msg(?id, "target", .{}) });
    }

    /// Queue mouse down, `drags` drags and up at `p` (content-view = window coordinates).
    fn postClick(mw: *mac.MacWindow, p: ak.NSPoint, drags: u32) void {
        const app = ak.sharedApp();
        const num = mw.native_window.msg(NSInteger, "windowNumber", .{});
        const now = ak.class("NSProcessInfo").msg(id, "processInfo", .{}).msg(f64, "systemUptime", .{});
        const types = [_]NSUInteger{ 1, 6, 2 }; // left mouse down, dragged, up
        var events: [8]NSUInteger = undefined;
        var k: usize = 0;
        events[k] = types[0];
        k += 1;
        for (0..@min(drags, 5)) |_| {
            events[k] = types[1];
            k += 1;
        }
        events[k] = types[2];
        k += 1;
        for (events[0..k], 0..) |ty, i| {
            const pt: ak.NSPoint = .{ .x = p.x + @as(f64, @floatFromInt(i)), .y = p.y };
            const ev = ak.class("NSEvent").msg(?id, "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
                ty, pt, @as(NSUInteger, 0), now + @as(f64, @floatFromInt(i)) * 0.01, num, @as(?id, null), @as(NSInteger, 0), @as(NSInteger, 1), @as(f32, if (ty == 2) 0 else 1),
            }) orelse return;
            app.msg(void, "postEvent:atStart:", .{ ev, objc.NO });
        }
    }
} else struct {
    fn activate(_: *Window) void {}
    fn axWalk(_: *Window, _: u64) u64 {
        return 0;
    }
    fn moveMouse(_: *Window, _: std.Random) void {}
    fn resize(_: *Window, _: usize) void {}
};

/// Browser smoke: open the tab, then poll every frame until the page loaded.
fn openBrowser(s: *State, win: *Window, app: *App, url: []const u8) void {
    const root = win.root orelse return failNow(s, app, "no root view");
    const shell = root.entity.downcast(shell_mod.Shell) orelse return failNow(s, app, "root view is not the shell");
    const rp = shell.read(app).right_pane;
    std.debug.print("zeron smoke: opening a Browser tab on {s}\n", .{url});
    const pane = rp.update(app, right_pane_mod.RightPane.addBrowser, .{ url, win }) orelse
        return failNow(s, app, "could not open a Browser tab (no selected chat?)");
    _ = pane;
    win.onNextFrame(BrowserWait{ .left = 1200, .settle = 30 }, BrowserWait.tick);
}

const BrowserWait = struct {
    left: u64,
    settle: u64,
    loaded: bool = false,
    fn tick(self: *const BrowserWait, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        const s = &state.?;
        if (browser.pane.smoke_failed.load(.acquire)) return failNow(s, app, "the browser page failed to load");
        var next = self.*;
        if (!next.loaded and browser.pane.smoke_loaded.load(.acquire)) {
            next.loaded = true;
            std.debug.print("zeron smoke: browser page loaded\n", .{});
        }
        if (next.loaded) {
            if (next.settle == 0) {
                if (s.opts.menu) return MenuProbe.begin(s, win, app);
                return Tick.finish(s, win, app);
            }
            next.settle -= 1;
        } else {
            if (next.left == 0) return failNow(s, app, "the browser page did not finish loading in time");
            next.left -= 1;
        }
        win.refresh(); // keep frames coming while the page paints
        win.onNextFrame(next, tick);
    }
};

/// ZERON_SMOKE_MENU: stripes → capture → frosted card over them → capture → compare.
const MenuProbe = struct {
    step: enum { stripes, menu },
    /// Frames to let the current step paint before capturing.
    settle: u32,
    /// High-frequency energy of the bare stripes (set after the first capture).
    bare: f64 = 0,

    const settle_frames = 6;

    fn begin(s: *State, win: *Window, app: *App) void {
        const shell = shellOf(win, app) orelse return failNow(s, app, "frosted menu check: root view is not the shell");
        std.debug.print("zeron smoke: frosted menu check: stripes, then a frosted card over them\n", .{});
        _ = shell.update(app, shell_mod.Shell.setSmokeProbe, .{.stripes});
        win.refresh();
        win.onNextFrame(MenuProbe{ .step = .stripes, .settle = settle_frames }, tick);
    }

    fn shellOf(win: *Window, app: *App) ?zpui.Entity(shell_mod.Shell) {
        const root = win.root orelse return null;
        _ = app;
        return root.entity.downcast(shell_mod.Shell);
    }

    fn tick(self: *const MenuProbe, win: *Window, app: *App) void {
        _ = frames_seen.fetchAdd(1, .monotonic);
        const s = &state.?;
        var next = self.*;
        if (next.settle > 0) {
            next.settle -= 1;
            // Read the planes of the last menu frame back (macOS overlay check).
            if (builtin.os.tag == .macos and next.step == .menu and next.settle == 1 and win.present_overlay.items.len > 0)
                macRenderer(win).armLayerCapture();
            win.refresh();
            return win.onNextFrame(next, tick);
        }
        const shell = shellOf(win, app) orelse return failNow(s, app, "frosted menu check: root view is not the shell");
        switch (next.step) {
            .stripes => {
                next.bare = measure(s, win, "menu-off") catch |err| return failErr(s, app, err);
                if (next.bare < 0.05) {
                    std.debug.print("FAIL: zeron smoke: frosted menu check: the stripes are not visible (energy {d:.4}); capture/geometry mismatch?\n", .{next.bare});
                    return failCode(s, app);
                }
                _ = shell.update(app, shell_mod.Shell.setSmokeProbe, .{.menu});
                win.refresh();
                next.step = .menu;
                next.settle = settle_frames;
                win.onNextFrame(next, tick);
            },
            .menu => {
                const under = measure(s, win, "menu") catch |err| return failErr(s, app, err);
                const ratio = under / next.bare;
                const layered = win.present_overlay.items.len > 0;
                std.debug.print("zeron smoke: frosted menu check: stripe energy bare {d:.4}, under the card {d:.4} (ratio {d:.3}); card on the {s}\n", .{ next.bare, under, ratio, if (layered) "overlay plane (native views present)" else "main plane" });
                if (builtin.os.tag == .macos) {
                    macRenderer(win).disarmLayerCapture();
                    if (layered) checkOverlayPlane(s, win, app) catch return;
                    if (!macRenderer(win).mps_supported) {
                        std.debug.print("SKIP: zeron smoke: frosted menu energy check: MetalPerformanceShaders is unsupported on this GPU (blurs draw unblurred)\n", .{});
                        return Tick.finish(s, win, app);
                    }
                }
                if (ratio >= 0.25) {
                    std.debug.print("FAIL: zeron smoke: frosted menu is not blurred: the content under it keeps {d:.0}% of its high-frequency energy (want < 25%)\n", .{ratio * 100});
                    return failCode(s, app);
                }
                std.debug.print("zeron smoke: frosted menu check passed\n", .{});
                Tick.finish(s, win, app);
            },
        }
    }

    fn macRenderer(win: *Window) *@TypeOf(zpui.mac_platform.MacWindow.fromWindow(win.platform_window).renderer) {
        return &zpui.mac_platform.MacWindow.fromWindow(win.platform_window).renderer;
    }

    /// macOS overlay plane: the card's blurred backdrop must be opaque (the planes
    /// beneath, composited); the regression left it transparent (its own empty plane).
    fn checkOverlayPlane(s: *State, win: *Window, app: *App) !void {
        if (builtin.os.tag != .macos) return;
        const r = macRenderer(win);
        const cap = r.takeLayerCapture(.overlay) orelse {
            std.debug.print("FAIL: zeron smoke: frosted menu check: no overlay-plane readback\n", .{});
            failCode(s, app);
            return error.Failed;
        };
        defer s.gpa.free(cap.rgba);
        const rect = pixelRect(win, cap.width, cap.height);
        var min_alpha: u8 = 255;
        var y = rect.y0;
        while (y < rect.y1) : (y += 1) {
            var x = rect.x0;
            while (x < rect.x1) : (x += 1) min_alpha = @min(min_alpha, cap.rgba[(y * cap.width + x) * 4 + 3]);
        }
        std.debug.print("zeron smoke: frosted menu check: overlay plane alpha under the card >= {d}\n", .{min_alpha});
        if (min_alpha < 250) {
            std.debug.print("FAIL: zeron smoke: frosted menu is not blurred: its overlay-plane backdrop is translucent (alpha {d}); the blur sampled its own plane, not the content beneath\n", .{min_alpha});
            failCode(s, app);
            return error.Failed;
        }
    }

    const PixelRect = struct { x0: usize, y0: usize, x1: usize, y1: usize };

    /// `smoke_probe.measureRect` in an image of the window's content (`width` x `height`;
    /// a taller image has the titlebar on top).
    fn pixelRect(win: *Window, width: u32, height: u32) PixelRect {
        const vp = win.viewportSize();
        const scale = @as(f32, @floatFromInt(width)) / vp.width;
        const top = @max(@as(f32, @floatFromInt(height)) - vp.height * scale, 0);
        const m = smoke_probe.measureRect();
        const cx = struct {
            fn f(v: f32, lim: u32) usize {
                return @intFromFloat(std.math.clamp(@round(v), 0, @as(f32, @floatFromInt(lim))));
            }
        }.f;
        return .{
            .x0 = cx(m.origin.x * scale, width),
            .x1 = cx((m.origin.x + m.size.width) * scale, width),
            .y0 = cx(top + m.origin.y * scale, height),
            .y1 = cx(top + (m.origin.y + m.size.height) * scale, height),
        };
    }

    /// Capture the window, write `<stem>-<tag>.png`, return the mean |d luma / dx|
    /// (0..1) over the measured rect.
    fn measure(s: *State, win: *Window, tag: []const u8) !f64 {
        const gpa = s.gpa;
        const img = switch (builtin.os.tag) {
            .macos => try captureMac(gpa, win.platform_window),
            .linux => try captureX11(gpa, s.io, win.platform_window),
            else => return error.CaptureUnsupportedOnThisOs,
        };
        defer gpa.free(img.pixels);
        var buf: [256]u8 = undefined;
        const base = s.opts.out orelse (if (builtin.os.tag == .macos) "zig-out/zeron-macos.png" else "zig-out/zeron-linux.png");
        const stem = if (std.mem.endsWith(u8, base, ".png")) base[0 .. base.len - 4] else base;
        const path = try std.fmt.bufPrint(&buf, "{s}-{s}.png", .{ stem, tag });
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
        if (encodePng(gpa, img.width, img.height, img.pixels)) |encoded| {
            defer gpa.free(encoded);
            std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = encoded }) catch {};
            std.debug.print("zeron smoke: wrote {s}\n", .{path});
        } else |_| {}
        return highFrequencyEnergy(img, pixelRect(win, img.width, img.height));
    }

    fn highFrequencyEnergy(img: Image, r: PixelRect) f64 {
        if (r.x1 <= r.x0 + 1 or r.y1 <= r.y0) return 0;
        var sum: f64 = 0;
        var n: usize = 0;
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            var prev = luma(img, r.x0, y);
            var x = r.x0 + 1;
            while (x < r.x1) : (x += 1) {
                const l = luma(img, x, y);
                sum += @abs(l - prev);
                prev = l;
                n += 1;
            }
        }
        return sum / @as(f64, @floatFromInt(n));
    }

    fn luma(img: Image, x: usize, y: usize) f64 {
        const p = img.pixels[(y * img.width + x) * 4 ..][0..3];
        return (0.2126 * @as(f64, @floatFromInt(p[0])) + 0.7152 * @as(f64, @floatFromInt(p[1])) + 0.0722 * @as(f64, @floatFromInt(p[2]))) / 255.0;
    }
};

fn failErr(s: *State, app: *App, err: anyerror) void {
    std.debug.print("FAIL: zeron smoke: frosted menu check: {t}\n", .{err});
    failCode(s, app);
}

fn failCode(s: *State, app: *App) void {
    s.exit_code = 1;
    s.done.store(true, .release);
    app.quit();
}

fn failNow(s: *State, app: *App, reason: []const u8) void {
    std.debug.print("FAIL: zeron smoke: {s}\n", .{reason});
    s.exit_code = 1;
    s.done.store(true, .release);
    app.quit();
}

fn watchdog(io: std.Io, timeout_s: i64, frames: u64) void {
    io.sleep(.fromSeconds(timeout_s), .awake) catch return;
    if (state) |*s| if (s.done.load(.acquire)) return;
    std.debug.print(
        \\FAIL: zeron smoke: only {d}/{d} frames presented within {d}s.
        \\      The window never got (enough) frames: no GPU/display (macOS: Metal device,
        \\      GUI session; Linux: DISPLAY + Vulkan ICD, e.g. VK_ICD_FILENAMES=lvp_icd.json).
        \\
    , .{ frames_seen.load(.monotonic), frames, timeout_s });
    std.process.exit(1);
}

const os_name = switch (builtin.os.tag) {
    .macos => "macos",
    .linux => "linux",
    else => @tagName(builtin.os.tag),
};

fn capture(s: *State, win: *Window) !void {
    const gpa = s.gpa;
    const img = switch (builtin.os.tag) {
        .macos => try captureMac(gpa, win.platform_window),
        .linux => try captureX11(gpa, s.io, win.platform_window),
        else => return error.CaptureUnsupportedOnThisOs,
    };
    defer gpa.free(img.pixels);

    var buf: [64]u8 = undefined;
    const path = s.opts.out orelse
        try std.fmt.bufPrint(&buf, "zig-out/zeron-{s}{s}.png", .{ os_name, if (s.opts.light) "-light" else "" });
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
    const encoded = try encodePng(gpa, img.width, img.height, img.pixels);
    defer gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = encoded });
    std.debug.print("zeron smoke: wrote {s} ({d}x{d})\n", .{ path, img.width, img.height });

    if (builtin.os.tag == .macos and s.opts.diag) diagnostics(s, win, path);

    const st = stats(img.pixels);
    std.debug.print("zeron smoke: {d:.2}% of pixels differ from the corner color, {d} distinct colors (quantized)\n", .{ st.differing * 100, st.distinct });
    if (st.differing < 0.01 or st.distinct < 8) return error.BlankFrame;
}

/// [glass-lab] ZERON_SMOKE_DIAG: glass diagnostics + the extra captures (see `Options.diag`).
fn diagnostics(s: *State, win: *Window, window_png: []const u8) void {
    if (builtin.os.tag != .macos) return;
    const gpa = s.gpa;
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const mw = mac.MacWindow.fromWindow(win.platform_window);
    mac.glass_debug.dump(mw, window_png);
    const stem = if (std.mem.endsWith(u8, window_png, ".png")) window_png[0 .. window_png.len - 4] else window_png;
    var buf: [256]u8 = undefined;
    inline for (.{ .{ .main, "metal-main" }, .{ .overlay, "metal-overlay" }, .{ .top, "metal-top" } }) |pl| {
        if (mw.renderer.takeLayerCapture(pl[0])) |cap| {
            defer gpa.free(cap.rgba);
            unpremultiply(cap.rgba);
            if (std.fmt.bufPrint(&buf, "{s}-{s}.png", .{ stem, pl[1] })) |p| writePngFile(s, p, cap.width, cap.height, cap.rgba) else |_| {}
        } else std.debug.print("zeron smoke: no {s} readback (plane not drawn while armed)\n", .{pl[1]});
    }
    if (captureMacImage(gpa, mac.glass_debug.windowRectCG(mw), cf.kCGWindowListOptionOnScreenOnly, cf.kCGNullWindowID, cf.kCGWindowImageBestResolution)) |img| {
        defer gpa.free(img.pixels);
        if (std.fmt.bufPrint(&buf, "{s}-onscreen.png", .{stem})) |p| writePngFile(s, p, img.width, img.height, img.pixels) else |_| {}
    } else |err| std.debug.print("zeron smoke: on-screen capture: {t}\n", .{err});
    const path = std.fmt.bufPrint(&buf, "{s}-screencapture.png", .{stem}) catch return;
    const res = std.process.run(gpa, s.io, .{
        .argv = &.{ "screencapture", "-x", "-t", "png", path },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("zeron smoke: screencapture: {t}\n", .{err});
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term.success()) std.debug.print("zeron smoke: wrote {s} (screencapture -x)\n", .{path}) else std.debug.print("zeron smoke: screencapture failed: {s}\n", .{res.stderr});
}

fn writePngFile(s: *State, path: []const u8, width: u32, height: u32, rgba: []const u8) void {
    const encoded = encodePng(s.gpa, width, height, rgba) catch return;
    defer s.gpa.free(encoded);
    std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = encoded }) catch |err| {
        std.debug.print("zeron smoke: write {s}: {t}\n", .{ path, err });
        return;
    };
    std.debug.print("zeron smoke: wrote {s} ({d}x{d})\n", .{ path, width, height });
}

pub const Image = struct { width: u32, height: u32, pixels: []u8 };

pub const Stats = struct { differing: f64, distinct: usize };

/// Fraction of pixels that differ from pixel 0 (by > 8 in any channel) and the
/// number of distinct colors after quantizing to 4 bits per channel.
pub fn stats(rgba: []const u8) Stats {
    const n = rgba.len / 4;
    if (n == 0) return .{ .differing = 0, .distinct = 0 };
    var seen: std.StaticBitSet(1 << 16) = .empty;
    var differing: usize = 0;
    const ref = rgba[0..4];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = rgba[i * 4 ..][0..4];
        var diff = false;
        for (p, ref) |a, b| diff = diff or @abs(@as(i16, a) - @as(i16, b)) > 8;
        if (diff) differing += 1;
        const key = (@as(u16, p[0] >> 4) << 12) | (@as(u16, p[1] >> 4) << 8) | (@as(u16, p[2] >> 4) << 4) | (p[3] >> 4);
        seen.set(key);
    }
    return .{ .differing = @as(f64, @floatFromInt(differing)) / @as(f64, @floatFromInt(n)), .distinct = seen.count() };
}

fn captureMac(gpa: std.mem.Allocator, pw: zpui.platform.Window) !Image {
    if (builtin.os.tag != .macos) unreachable;
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const number = mac.MacWindow.fromWindow(pw).windowNumber();
    return captureMacImage(gpa, cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, number, cf.kCGWindowImageBoundsIgnoreFraming | cf.kCGWindowImageBestResolution);
}

/// `CGWindowListCreateImage(rect, list_option, window_number, image_option)` as straight
/// RGBA8 (the window alone: `CGRectNull` + IncludingWindow; what the display shows in a
/// rect: the rect + OnScreenOnly + window 0).
pub fn captureMacImage(gpa: std.mem.Allocator, rect: zpui.mac_platform.cf.CGRect, list_option: u32, window_number: u32, image_option: u32) !Image {
    if (builtin.os.tag != .macos) unreachable;
    const cf = zpui.mac_platform.cf;
    const create_image = cf.cgWindowListCreateImage() orelse return error.CGWindowListCreateImageUnavailable;
    const image = create_image(rect, list_option, window_number, image_option) orelse
        return error.CGWindowListCreateImageReturnedNull; // no Screen Recording permission?
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
    unpremultiply(pixels);
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}

/// X11 only: crops the window's rectangle out of the root window with
/// ImageMagick's `import` (PPM on stdout, parsed here).
pub fn captureX11(gpa: std.mem.Allocator, io: std.Io, pw: zpui.platform.Window) !Image {
    const b = pw.bounds();
    const scale = pw.scaleFactor();
    const content = pw.contentSize();
    const w: u32 = @intFromFloat(@round(content.width * scale));
    const h: u32 = @intFromFloat(@round(content.height * scale));
    const x: i32 = @intFromFloat(@round(b.origin.x * scale));
    const y: i32 = @intFromFloat(@round(b.origin.y * scale));
    var crop_buf: [64]u8 = undefined;
    const crop = try std.fmt.bufPrint(&crop_buf, "{d}x{d}+{d}+{d}", .{ w, h, @max(x, 0), @max(y, 0) });
    std.debug.print("zeron smoke: import -window root -crop {s}\n", .{crop});
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "import", "-window", "root", "-crop", crop, "+repage", "-depth", "8", "ppm:-" },
        .stdout_limit = .limited(256 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("zeron smoke: could not run ImageMagick `import` ({t}); install imagemagick (X11 only)\n", .{err});
        return error.ImportUnavailable;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.term.success()) {
        std.debug.print("zeron smoke: import failed: {s}\n", .{res.stderr});
        return error.ImportFailed;
    }
    return parsePpm(gpa, res.stdout);
}

/// Binary PPM (P6, maxval 255) → RGBA8 (alpha 255).
fn parsePpm(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    var pos: usize = 0;
    var fields: [4]u32 = undefined; // magic placeholder, width, height, maxval
    if (bytes.len < 2 or !std.mem.eql(u8, bytes[0..2], "P6")) return error.NotPpm;
    pos = 2;
    for (fields[1..]) |*f| {
        while (pos < bytes.len) {
            if (bytes[pos] == '#') {
                while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
            } else if (std.ascii.isWhitespace(bytes[pos])) pos += 1 else break;
        }
        const start_pos = pos;
        while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) pos += 1;
        f.* = std.fmt.parseInt(u32, bytes[start_pos..pos], 10) catch return error.BadPpmHeader;
    }
    pos += 1; // single whitespace before the raster
    const w = fields[1];
    const h = fields[2];
    if (fields[3] != 255) return error.UnsupportedPpmDepth;
    const n = @as(usize, w) * h;
    if (bytes.len < pos + n * 3) return error.TruncatedPpm;
    const pixels = try gpa.alloc(u8, n * 4);
    for (0..n) |i| {
        pixels[i * 4 ..][0..3].* = bytes[pos + i * 3 ..][0..3].*;
        pixels[i * 4 + 3] = 255;
    }
    return .{ .width = w, .height = h, .pixels = pixels };
}

pub fn unpremultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}

// Minimal RGBA8 PNG encoder (same as examples/png.zig, which this module can't import).
pub fn encodePng(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    const flate = std.compress.flate;
    const stride = @as(usize, width) * 4;
    var raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const row = pixels[y * stride ..][0..stride];
        const out = raw[y * (stride + 1) ..][0 .. stride + 1];
        out[0] = 1; // Sub filter
        for (row, 0..) |byte, i| out[1 + i] = byte -% (if (i >= 4) row[i - 4] else 0);
    }
    var zlib: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer zlib.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compress = try flate.Compress.init(&zlib.writer, window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", zlib.written());
    try writeChunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "ppm parse + blank detection" {
    const gpa = std.testing.allocator;
    const ppm = "P6\n# c\n2 1\n255\n" ++ "\x00\x00\x00\xff\xff\xff";
    const img = try parsePpm(gpa, ppm);
    defer gpa.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 }, img.pixels);
    var flat: [64 * 4]u8 = undefined;
    for (0..64) |i| flat[i * 4 ..][0..4].* = .{ 10, 10, 10, 255 };
    const st = stats(&flat);
    try std.testing.expect(st.differing == 0 and st.distinct == 1);
    const png = try encodePng(gpa, 2, 1, img.pixels);
    defer gpa.free(png);
    try std.testing.expectEqualSlices(u8, "\x89PNG", png[0..4]);
}
