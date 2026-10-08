//! `ZERON_SMOKE_NATIVE_MENU=context|more` (macOS, CI): open a native menu through real
//! AppKit events and capture the whole screen with `screencapture -x` while it is up
//! (NSMenus are their own windows, so the window capture would miss them).
//!
//! * `context`: a right-click on a sidebar chat row (the chat context menu: Rename, Pin,
//!   Archive, Copy ▸, Delete…).
//! * `more`: a click on the sidebar's "⋯" view options button (Organize ▸, Sort ▸,
//!   Show ▸, Compact, Create Section).
//!
//! The target is found in the accessibility tree (chat row by its fixture title, the
//! button by its label). The events are posted to NSApp; the menu then tracks in
//! AppKit's nested loop, so a helper thread waits, captures to `ZERON_SMOKE_OUT`, and
//! ends the process: exit 0 with `PASS: zeron smoke: native menu …` when a native menu
//! was shown and the capture exists, else `FAIL: …` and exit 1.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const native_menu = @import("ui/components/native_menu.zig");

const App = zpui.App;
const Window = zpui.Window;

pub const Which = enum { context, more };

/// The reference fixture's first chat (`apps/zeron/fixtures/reference`).
const chat_title = "Add backpressure to stream pipeline";

const Run = struct {
    io: std.Io,
    which: Which,
    out: []const u8,
    waited: u32 = 0,
    center: zpui.Point(f32) = .{ .x = 0, .y = 0 },
    label: []const u8 = "",
};

var run_state: Run = undefined;

pub fn begin(io: std.Io, win: *Window, which_name: []const u8, out: []const u8) void {
    const which = std.meta.stringToEnum(Which, which_name) orelse {
        std.debug.print("FAIL: zeron smoke: ZERON_SMOKE_NATIVE_MENU={s} (want context or more)\n", .{which_name});
        std.process.exit(1);
    };
    if (builtin.os.tag != .macos) {
        std.debug.print("SKIP: zeron smoke: native menus are macOS only\n", .{});
        std.process.exit(0);
    }
    run_state = .{ .io = io, .which = which, .out = out };
    win.setA11yActive(true);
    win.refresh();
    win.onNextFrame({}, locate);
}

fn findLabel(tree: *const zpui.a11y.Tree, label: []const u8) ?zpui.Bounds(f32) {
    for (tree.nodes.items) |n| {
        const l = tree.str(n.label) orelse continue;
        if (std.mem.eql(u8, l, label) and n.bounds.size.width > 0) return n.bounds;
    }
    return null;
}

fn locate(_: *const void, win: *Window, _: *App) void {
    const tree = win.a11yTree();
    const label = switch (run_state.which) {
        .context => chat_title,
        .more => "Sidebar view options",
    };
    const b = findLabel(tree, label) orelse {
        if (run_state.waited < 30) {
            run_state.waited += 1;
            win.refresh();
            return win.onNextFrame({}, locate);
        }
        std.debug.print("FAIL: zeron smoke: no \"{s}\" element to open a native menu from\n", .{label});
        std.process.exit(1);
    };
    win.setA11yActive(false);
    run_state.center = .{ .x = b.origin.x + @min(b.size.width / 2, 60), .y = b.origin.y + b.size.height / 2 };
    run_state.label = label;
    // A click on an inactive window only activates it (AppKit never delivers it to
    // the view): bring the app forward and wait until the window is key.
    Mac.activate(win);
    run_state.waited = 0;
    win.refresh();
    win.onNextFrame({}, clickWhenKey);
}

fn clickWhenKey(_: *const void, win: *Window, _: *App) void {
    if (!Mac.isKey(win) and run_state.waited < 120) {
        run_state.waited += 1;
        if (run_state.waited % 30 == 0) Mac.activate(win);
        win.refresh();
        return win.onNextFrame({}, clickWhenKey);
    }
    const center = run_state.center;
    std.debug.print("zeron smoke: native menu {t}: clicking \"{s}\" at {d:.0},{d:.0} (window key: {}, after {d} frames)\n", .{ run_state.which, run_state.label, center.x, center.y, Mac.isKey(win), run_state.waited });
    Mac.click(win, center, run_state.which == .context);
    if (std.Thread.spawn(.{}, captureLater, .{})) |t| t.detach() else |err| {
        std.debug.print("FAIL: zeron smoke: capture thread: {t}\n", .{err});
        std.process.exit(1);
    }
}

/// Off the main thread (which is inside the menu's tracking loop): wait for the menu
/// to settle, capture the screen, end the process.
fn captureLater() void {
    const io = run_state.io;
    io.sleep(.fromSeconds(2), .awake) catch {};
    const shown = native_menu.shown_count.load(.acquire);
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "screencapture", "-x", "-t", "png", run_state.out },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("FAIL: zeron smoke: screencapture: {t}\n", .{err});
        std.process.exit(1);
    };
    if (!res.term.success()) {
        std.debug.print("FAIL: zeron smoke: screencapture failed: {s}\n", .{res.stderr});
        std.process.exit(1);
    }
    // Captured either way, so a failure shows what was on screen instead.
    if (shown == 0) {
        std.debug.print("FAIL: zeron smoke: no native menu was shown (drawn fallback?); screen in {s}\n", .{run_state.out});
        std.process.exit(1);
    }
    std.debug.print("PASS: zeron smoke: native menu {t} shown ({d}), wrote {s} (screencapture -x)\n", .{ run_state.which, shown, run_state.out });
    std.process.exit(0);
}

const Mac = if (builtin.os.tag == .macos) struct {
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

    fn isKey(win: *Window) bool {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        return objc.fromBOOL(mw.native_window.msg(objc.BOOL, "isKeyWindow", .{})) and
            objc.fromBOOL(ak.sharedApp().msg(objc.BOOL, "isActive", .{}));
    }

    /// Post a mouse move, then a left click or a right mouse down + up, at `p`
    /// (window coordinates).
    fn click(win: *Window, p: zpui.Point(f32), right: bool) void {
        const mw = mac.MacWindow.fromWindow(win.platform_window);
        const height = ak.bounds(mw.native_view).size.height;
        const pt: ak.NSPoint = .{ .x = p.x, .y = height - @as(f64, p.y) };
        const num = mw.native_window.msg(NSInteger, "windowNumber", .{});
        const now = ak.class("NSProcessInfo").msg(id, "processInfo", .{}).msg(f64, "systemUptime", .{});
        // NSEventType: mouse moved 5 (hover first), left down 1 / up 2, right down 3 / up 4.
        const types = if (right) [_]NSUInteger{ 5, 3, 4 } else [_]NSUInteger{ 5, 1, 2 };
        for (types, 0..) |ty, i| {
            const ev = ak.class("NSEvent").msg(?id, "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
                ty, pt, @as(NSUInteger, 0), now + @as(f64, @floatFromInt(i)) * 0.05, num, @as(?id, null), @as(NSInteger, 0), @as(NSInteger, 1), @as(f32, if (ty == 3 or ty == 1) 1 else 0),
            }) orelse return;
            ak.sharedApp().msg(void, "postEvent:atStart:", .{ withButton(ev, if (ty == 3 or ty == 4) 1 else 0), objc.NO });
        }
    }

    extern "c" fn CGEventCreateCopy(event: ?*anyopaque) ?*anyopaque;
    extern "c" fn CGEventSetIntegerValueField(event: ?*anyopaque, field: u32, value: i64) void;
    extern "c" fn CFRelease(cf: ?*anyopaque) void;
    /// kCGMouseEventButtonNumber.
    const button_number_field: u32 = 3;

    /// `mouseEventWithType:` leaves `buttonNumber` at 0, which the window reads as the
    /// left button (a real right click carries 1): set it through the event's CGEvent.
    fn withButton(ev: id, button: i64) id {
        if (button == 0) return ev;
        const cg = ev.msg(?*anyopaque, "CGEvent", .{}) orelse return ev;
        const copy = CGEventCreateCopy(cg) orelse return ev;
        defer CFRelease(copy);
        CGEventSetIntegerValueField(copy, button_number_field, button);
        return ak.class("NSEvent").msg(?id, "eventWithCGEvent:", .{copy}) orelse ev;
    }
} else struct {
    fn activate(_: *Window) void {}
    fn isKey(_: *Window) bool {
        return true;
    }
    fn click(_: *Window, _: zpui.Point(f32), _: bool) void {}
};
