//! `ZERON_SMOKE_SHORTCUTS=1` (macOS CI, with `--smoke-frames N --fixtures …`): the
//! menu bar and keyboard shortcuts through the real AppKit paths.
//!
//! After the N frames the app is activated and, for every app shortcut of
//! `shortcut_table.zig` (plus the composer's editing chords), a real key-down/key-up
//! `NSEvent` pair is queued with `-[NSApp postEvent:atStart:]`. AppKit then runs its own
//! routing (`-[NSApplication sendEvent:]` → key equivalents through the key window's
//! `performKeyEquivalent:` and the main menu, else `keyDown:` on the first responder),
//! exactly like a keypress. A case passes when zpui's action trace reports the action
//! handled within a few frames. Each table runs with focus on the shell root, in the
//! message composer and after a blur (a click outside the composer). Then the main menu
//! is inspected (`-[NSMenu update]` runs `validateMenuItem:`): every item's title, key
//! equivalent and enabled state must match the Rust menu bar (`app_menus.rs`), and a
//! set of items is picked with `-[NSMenu performActionForItemAtIndex:]`. Finally ⌘Q
//! must quit the app. Prints `PASS: zeron smoke: shortcuts …` or one `FAIL:` line per
//! broken case (exit 1).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const table = @import("shortcut_table.zig");
const shell_mod = @import("ui/shell/shell.zig");

const App = zpui.App;
const Window = zpui.Window;

// ---- action trace (main thread only) ------------------------------------------------------

var trace_names: [64][]const u8 = undefined;
var trace_handled: [64]bool = undefined;
var trace_len: usize = 0;

fn trace(a: *const zpui.AnyAction, handled: bool) void {
    if (trace_len == trace_names.len) return;
    trace_names[trace_len] = a.name;
    trace_handled[trace_len] = handled;
    trace_len += 1;
}

fn firedHandled(name: []const u8) bool {
    for (trace_names[0..trace_len], trace_handled[0..trace_len]) |n, h| if (h and std.mem.eql(u8, n, name)) return true;
    return false;
}

fn printTrace() void {
    if (trace_len == 0) std.debug.print("      (no action dispatched)\n", .{});
    for (trace_names[0..trace_len], trace_handled[0..trace_len]) |n, h| std.debug.print("      dispatched {s} handled={}\n", .{ n, h });
}

// ---- the plan -----------------------------------------------------------------------------

const Focus = enum { root, composer, blurred };

const Step = union(enum) {
    focus: Focus,
    key: struct { keys: []const u8, action: []const u8, informational: bool = false },
    escape,
    menu_check,
    menu_pick: struct { menu: []const u8, item: []const u8, action: []const u8 },
    quit,
};

fn tableSteps(comptime focus: Focus) []const Step {
    comptime var out: []const Step = &.{.{ .focus = focus }};
    inline for (table.global) |c| {
        const keys = comptime table.keysFor(c, true);
        out = out ++ &[_]Step{.{ .key = .{ .keys = keys, .action = c.action } }};
        if (c.toggle) out = out ++ &[_]Step{ .{ .focus = focus }, .{ .key = .{ .keys = keys, .action = c.action } } };
        if (c.escape_after) out = out ++ &[_]Step{.escape};
        out = out ++ &[_]Step{.{ .focus = focus }};
    }
    return out;
}

const plan: []const Step = tableSteps(.root) ++ tableSteps(.composer) ++ tableSteps(.blurred) ++ &[_]Step{
    // ⌘N is owned by the "new chat from everywhere" work: reported, not failed.
    .{ .focus = .root },
    .{ .key = .{ .keys = "cmd-n", .action = "shell::NewSession", .informational = true } },
    // The composer's editing chords (Edit menu key equivalents).
    .{ .focus = .composer },
    .{ .key = .{ .keys = "cmd-a", .action = "composer::SelectAll" } },
    .{ .key = .{ .keys = "cmd-c", .action = "composer::Copy" } },
    .{ .key = .{ .keys = "cmd-z", .action = "composer::Undo" } },
    .{ .key = .{ .keys = "shift-cmd-z", .action = "composer::Redo" } },
    .menu_check,
    .{ .menu_pick = .{ .menu = "Edit", .item = "Select All", .action = "composer::SelectAll" } },
    .{ .menu_pick = .{ .menu = "Edit", .item = "Undo", .action = "composer::Undo" } },
    .{ .focus = .root },
    .{ .menu_pick = .{ .menu = "Zeron", .item = "Settings", .action = "shell::OpenSettings" } },
    .{ .menu_pick = .{ .menu = "Zeron", .item = "Settings", .action = "shell::OpenSettings" } },
    .{ .menu_pick = .{ .menu = "View", .item = "Appearance: Dark", .action = "zeron::AppearanceDark" } },
    .{ .menu_pick = .{ .menu = "Window", .item = "Zoom", .action = "zeron::Zoom" } },
    .{ .menu_pick = .{ .menu = "Window", .item = "Zoom", .action = "zeron::Zoom" } },
    .{ .focus = .blurred },
    .{ .menu_pick = .{ .menu = "Zeron", .item = "Settings", .action = "shell::OpenSettings" } },
    .{ .menu_pick = .{ .menu = "Zeron", .item = "Settings", .action = "shell::OpenSettings" } },
    .quit,
};

/// The Rust menu bar (`app_menus.rs` on macOS) with its key equivalents
/// (`app_key_bindings` + the keymap; "" = none). Separators are skipped.
const MenuRow = struct { menu: []const u8, title: []const u8, key: []const u8 = "", mods: []const u8 = "", always_enabled: bool = false };
const expected_menus = [_]MenuRow{
    .{ .menu = "Zeron", .title = "About Zeron", .always_enabled = true },
    .{ .menu = "Zeron", .title = "Check for Updates…", .always_enabled = true },
    .{ .menu = "Zeron", .title = "Settings", .key = ",", .mods = "cmd", .always_enabled = true },
    .{ .menu = "Zeron", .title = "Services" },
    .{ .menu = "Zeron", .title = "Hide Zeron", .key = "h", .mods = "cmd", .always_enabled = true },
    .{ .menu = "Zeron", .title = "Hide Others", .key = "h", .mods = "alt-cmd", .always_enabled = true },
    .{ .menu = "Zeron", .title = "Show All", .always_enabled = true },
    .{ .menu = "Zeron", .title = "Quit Zeron", .key = "q", .mods = "cmd", .always_enabled = true },
    // Zeron-Zig addition (no File menu in Rust): ⌘N as a menu key equivalent.
    .{ .menu = "File", .title = "New Chat", .key = "n", .mods = "cmd", .always_enabled = true },
    .{ .menu = "Edit", .title = "Undo", .key = "z", .mods = "cmd" },
    .{ .menu = "Edit", .title = "Redo", .key = "z", .mods = "shift-cmd" },
    .{ .menu = "Edit", .title = "Cut", .key = "x", .mods = "cmd" },
    .{ .menu = "Edit", .title = "Copy", .key = "c", .mods = "cmd" },
    .{ .menu = "Edit", .title = "Paste", .key = "v", .mods = "cmd" },
    .{ .menu = "Edit", .title = "Select All", .key = "a", .mods = "cmd" },
    .{ .menu = "View", .title = "Appearance: System", .always_enabled = true },
    .{ .menu = "View", .title = "Appearance: Light", .always_enabled = true },
    .{ .menu = "View", .title = "Appearance: Dark", .always_enabled = true },
    .{ .menu = "Window", .title = "Minimize", .key = "m", .mods = "cmd", .always_enabled = true },
    .{ .menu = "Window", .title = "Zoom", .always_enabled = true },
    .{ .menu = "Window", .title = "Close Window", .key = "w", .mods = "cmd", .always_enabled = true },
};

// ---- runner -------------------------------------------------------------------------------

pub const Result = struct { failures: u32, passes: u32 };

pub const Done = *const fn (win: *Window, app: *App, result: Result) void;

var on_done: ?Done = null;

pub fn begin(win: *Window, app: *App, done: Done) void {
    _ = app;
    on_done = done;
    zpui.window.dispatch_mod.action_trace = trace;
    std.debug.print("zeron smoke: shortcuts: {d} steps\n", .{plan.len});
    if (builtin.os.tag == .macos) mac.activate(win);
    win.onNextFrame(Runner{ .wait = 20 }, Runner.tick);
}

const Runner = struct {
    ix: usize = 0,
    /// Frames left before acting (activation / settling) or checking (a posted key).
    wait: u32 = 0,
    pending: bool = false,
    failures: u32 = 0,
    passes: u32 = 0,
    quit_frames: u32 = 0,

    fn tick(self: *const Runner, win: *Window, app: *App) void {
        var next = self.*;
        win.refresh();
        if (next.wait > 0) {
            next.wait -= 1;
            return win.onNextFrame(next, tick);
        }
        if (next.quit_frames > 0) {
            // ⌘Q was posted: the app should be gone by now.
            next.quit_frames -= 1;
            if (next.quit_frames == 0) {
                std.debug.print("FAIL: zeron smoke: shortcuts: cmd-q did not quit\n", .{});
                printTrace();
                next.failures += 1;
                return finish(win, app, next);
            }
            return win.onNextFrame(next, tick);
        }
        if (next.pending) {
            next.pending = false;
            next.check(plan[next.ix]);
            next.ix += 1;
        }
        if (next.ix >= plan.len) return finish(win, app, next);
        const step = plan[next.ix];
        trace_len = 0;
        switch (step) {
            .focus => |f| {
                setFocus(win, app, f);
                next.ix += 1;
                next.wait = 2;
            },
            .escape => {
                if (builtin.os.tag == .macos) mac.postKey(win, "escape");
                next.ix += 1;
                next.wait = 3;
            },
            .key => |k| {
                if (builtin.os.tag == .macos) mac.postKey(win, k.keys);
                next.pending = true;
                next.wait = 4;
            },
            .menu_check => {
                if (builtin.os.tag == .macos) {
                    const bad = mac.checkMenus();
                    next.failures += bad;
                    if (bad == 0) next.passes += 1;
                }
                next.ix += 1;
            },
            .menu_pick => |m| {
                if (builtin.os.tag == .macos and !mac.pick(m.menu, m.item)) {
                    std.debug.print("FAIL: zeron smoke: shortcuts: menu {s} > {s} not found or disabled\n", .{ m.menu, m.item });
                    next.failures += 1;
                    next.ix += 1;
                } else {
                    next.pending = true;
                    next.wait = 4;
                }
            },
            .quit => {
                std.debug.print("zeron smoke: shortcuts: {d} passed, {d} failed; posting cmd-q\n", .{ next.passes, next.failures });
                if (on_done) |d| d(win, app, .{ .failures = next.failures, .passes = next.passes });
                if (builtin.os.tag == .macos) mac.postKey(win, "cmd-q");
                next.quit_frames = 240;
            },
        }
        win.onNextFrame(next, tick);
    }

    fn check(self: *Runner, step: Step) void {
        switch (step) {
            .key => |k| if (firedHandled(k.action)) {
                self.passes += 1;
                std.debug.print("zeron smoke: shortcuts: ok   {s} → {s}\n", .{ k.keys, k.action });
            } else if (k.informational) {
                std.debug.print("INFO: zeron smoke: shortcuts: {s} did not fire {s} (not counted)\n", .{ k.keys, k.action });
                printTrace();
            } else {
                self.failures += 1;
                std.debug.print("FAIL: zeron smoke: shortcuts: {s} did not fire {s} (focus {s})\n", .{ k.keys, k.action, @tagName(current_focus) });
                printTrace();
            },
            .menu_pick => |m| if (firedHandled(m.action)) {
                self.passes += 1;
                std.debug.print("zeron smoke: shortcuts: ok   menu {s} > {s} → {s}\n", .{ m.menu, m.item, m.action });
            } else {
                self.failures += 1;
                std.debug.print("FAIL: zeron smoke: shortcuts: menu {s} > {s} did not fire {s}\n", .{ m.menu, m.item, m.action });
                printTrace();
            },
            else => {},
        }
    }

    fn finish(win: *Window, app: *App, r: Runner) void {
        zpui.window.dispatch_mod.action_trace = null;
        if (on_done) |d| d(win, app, .{ .failures = r.failures, .passes = r.passes });
        app.quit();
    }
};

var current_focus: Focus = .root;

fn setFocus(win: *Window, app: *App, f: Focus) void {
    current_focus = f;
    const root = win.root orelse return;
    const shell = root.entity.downcast(shell_mod.Shell) orelse return;
    switch (f) {
        .root => win.focus(shell.read(app).focus),
        .composer => {
            const c = shell.read(app).main.read(app).slots.composer_view;
            win.focus(c.read(app).input.read(app).focus);
        },
        .blurred => {
            const c = shell.read(app).main.read(app).slots.composer_view;
            win.focus(c.read(app).input.read(app).focus);
            win.blur();
        },
    }
}

const mac = if (builtin.os.tag == .macos) struct {
    const mp = zpui.mac_platform;
    const objc = mp.objc_runtime;
    const ak = mp.appkit;
    const id = objc.id;
    const NSInteger = isize;
    const NSUInteger = usize;

    fn activate(win: *Window) void {
        const mw = mp.MacWindow.fromWindow(win.platform_window);
        ak.sharedApp().msg(void, "activateIgnoringOtherApps:", .{objc.YES});
        mw.native_window.msg(void, "makeKeyAndOrderFront:", .{@as(?id, null)});
    }

    /// US ANSI virtual key codes (Carbon `kVK_*`).
    fn keyCode(key: []const u8) ?u16 {
        const named = [_]struct { []const u8, u16 }{
            .{ "tab", 48 },  .{ "escape", 53 }, .{ "enter", 36 }, .{ "space", 49 }, .{ "backspace", 51 },
            .{ "left", 123 }, .{ "right", 124 }, .{ "down", 125 }, .{ "up", 126 },
        };
        for (named) |n| if (std.mem.eql(u8, key, n[0])) return n[1];
        if (key.len != 1) return null;
        const chars = "asdfhgzxcv\x00bqweryt123465=97-80]ou[ip\x00lj'k;\\,/nm.";
        const ix = std.mem.indexOfScalar(u8, chars, key[0]) orelse return null;
        return @intCast(ix);
    }

    /// Queue key down + up for `combo` (gpui spelling: `cmd-shift-n`, `ctrl-tab`).
    fn postKey(win: *Window, combo: []const u8) void {
        const mw = mp.MacWindow.fromWindow(win.platform_window);
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        var flags: NSUInteger = 0;
        var shift = false;
        var key: []const u8 = combo;
        var it = std.mem.splitScalar(u8, combo, '-');
        while (it.next()) |part| {
            if (it.peek() == null) {
                key = if (part.len == 0) "-" else part;
                break;
            }
            const M = ak.NSEventModifierFlags;
            if (std.mem.eql(u8, part, "cmd")) flags |= M.command;
            if (std.mem.eql(u8, part, "ctrl")) flags |= M.control;
            if (std.mem.eql(u8, part, "alt")) flags |= M.option;
            if (std.mem.eql(u8, part, "shift")) {
                flags |= M.shift;
                shift = true;
            }
        }
        const code = keyCode(key) orelse {
            std.debug.print("WARN: zeron smoke: shortcuts: no key code for {s}\n", .{combo});
            return;
        };
        var chars_buf: [4]u8 = undefined;
        const chars: []const u8 = if (std.mem.eql(u8, key, "tab")) (if (shift) "\x19" else "\t") else if (std.mem.eql(u8, key, "escape")) "\x1b" else if (std.mem.eql(u8, key, "enter")) "\r" else if (std.mem.eql(u8, key, "space")) " " else if (key.len == 1) blk: {
            chars_buf[0] = if (shift) std.ascii.toUpper(key[0]) else key[0];
            break :blk chars_buf[0..1];
        } else "";
        const num = mw.native_window.msg(NSInteger, "windowNumber", .{});
        const now = ak.class("NSProcessInfo").msg(id, "processInfo", .{}).msg(f64, "systemUptime", .{});
        const app = ak.sharedApp();
        std.debug.print("zeron smoke: shortcuts: post {s} (key window: {}, active: {})\n", .{
            combo,
            mw.native_window.msg(objc.BOOL, "isKeyWindow", .{}) == objc.YES,
            app.msg(objc.BOOL, "isActive", .{}) == objc.YES,
        });
        for ([_]NSUInteger{ 10, 11 }, 0..) |ty, i| { // NSEventTypeKeyDown, KeyUp
            const ev = ak.class("NSEvent").msg(?id, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
                ty,                 ak.NSPoint{ .x = 0, .y = 0 }, flags,                 now + @as(f64, @floatFromInt(i)) * 0.01, num, @as(?id, null),
                ak.nsString(chars), ak.nsString(chars),           @as(objc.BOOL, objc.NO), code,
            }) orelse return;
            app.msg(void, "postEvent:atStart:", .{ ev, objc.NO });
        }
    }

    fn findSubmenu(name: []const u8) ?id {
        const bar = ak.sharedApp().msg(?id, "mainMenu", .{}) orelse return null;
        const n = bar.msg(NSInteger, "numberOfItems", .{});
        var i: NSInteger = 0;
        while (i < n) : (i += 1) {
            const item = bar.msg(id, "itemAtIndex:", .{i});
            const sub = item.msg(?id, "submenu", .{}) orelse continue;
            // The first menu is titled with the process name by AppKit; ours is "Zeron".
            if (std.mem.eql(u8, ak.stringBytes(sub.msg(id, "title", .{})), name) or (i == 0 and std.mem.eql(u8, name, "Zeron"))) return sub;
        }
        return null;
    }

    fn findItem(menu: id, title: []const u8) ?NSInteger {
        const n = menu.msg(NSInteger, "numberOfItems", .{});
        var i: NSInteger = 0;
        while (i < n) : (i += 1) {
            const item = menu.msg(id, "itemAtIndex:", .{i});
            if (std.mem.eql(u8, ak.stringBytes(item.msg(id, "title", .{})), title)) return i;
        }
        return null;
    }

    fn modsName(buf: []u8, mask: NSUInteger) []const u8 {
        const M = ak.NSEventModifierFlags;
        var w: std.Io.Writer = .fixed(buf);
        if (mask & M.control != 0) w.writeAll("ctrl-") catch {};
        if (mask & M.option != 0) w.writeAll("alt-") catch {};
        if (mask & M.shift != 0) w.writeAll("shift-") catch {};
        if (mask & M.command != 0) w.writeAll("cmd-") catch {};
        const s = w.buffered();
        return if (s.len > 0) s[0 .. s.len - 1] else s;
    }

    /// Validate every menu and compare it with `expected_menus`; returns the failures.
    fn checkMenus() u32 {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        var bad: u32 = 0;
        const bar = ak.sharedApp().msg(?id, "mainMenu", .{}) orelse {
            std.debug.print("FAIL: zeron smoke: shortcuts: no main menu\n", .{});
            return 1;
        };
        const n = bar.msg(NSInteger, "numberOfItems", .{});
        std.debug.print("zeron smoke: shortcuts: menu bar ({d} menus):\n", .{n});
        var i: NSInteger = 0;
        while (i < n) : (i += 1) {
            const holder = bar.msg(id, "itemAtIndex:", .{i});
            const sub = holder.msg(?id, "submenu", .{}) orelse continue;
            sub.msg(void, "update", .{}); // runs validateMenuItem: (autoenablesItems)
            std.debug.print("  [{s}]\n", .{ak.stringBytes(sub.msg(id, "title", .{}))});
            const m = sub.msg(NSInteger, "numberOfItems", .{});
            var j: NSInteger = 0;
            while (j < m) : (j += 1) {
                const it = sub.msg(id, "itemAtIndex:", .{j});
                if (it.msg(objc.BOOL, "isSeparatorItem", .{}) == objc.YES) continue;
                var buf: [32]u8 = undefined;
                std.debug.print("    {s:<22} key \"{s}\" mods {s:<10} enabled {}\n", .{
                    ak.stringBytes(it.msg(id, "title", .{})),
                    ak.stringBytes(it.msg(id, "keyEquivalent", .{})),
                    modsName(&buf, it.msg(NSUInteger, "keyEquivalentModifierMask", .{})),
                    it.msg(objc.BOOL, "isEnabled", .{}) == objc.YES,
                });
            }
        }
        for (expected_menus) |row| {
            const sub = findSubmenu(row.menu) orelse {
                std.debug.print("FAIL: zeron smoke: shortcuts: menu {s} missing\n", .{row.menu});
                bad += 1;
                continue;
            };
            const ix = findItem(sub, row.title) orelse {
                std.debug.print("FAIL: zeron smoke: shortcuts: menu {s} > {s} missing\n", .{ row.menu, row.title });
                bad += 1;
                continue;
            };
            const it = sub.msg(id, "itemAtIndex:", .{ix});
            const key = ak.stringBytes(it.msg(id, "keyEquivalent", .{}));
            var buf: [32]u8 = undefined;
            const mods = if (key.len == 0) "" else modsName(&buf, it.msg(NSUInteger, "keyEquivalentModifierMask", .{}));
            if (!std.mem.eql(u8, key, row.key) or !std.mem.eql(u8, mods, row.mods)) {
                std.debug.print("FAIL: zeron smoke: shortcuts: menu {s} > {s} key \"{s}\" {s}, want \"{s}\" {s}\n", .{ row.menu, row.title, key, mods, row.key, row.mods });
                bad += 1;
            }
            if (row.always_enabled and it.msg(objc.BOOL, "isEnabled", .{}) != objc.YES) {
                std.debug.print("FAIL: zeron smoke: shortcuts: menu {s} > {s} is disabled\n", .{ row.menu, row.title });
                bad += 1;
            }
        }
        // Services is AppKit's Services menu; Window is NSApp's windows menu.
        const app = ak.sharedApp();
        if (app.msg(?id, "servicesMenu", .{}) == null) {
            std.debug.print("FAIL: zeron smoke: shortcuts: no Services menu\n", .{});
            bad += 1;
        }
        if (app.msg(?id, "windowsMenu", .{}) == null) {
            std.debug.print("FAIL: zeron smoke: shortcuts: no Window menu registered with NSApp\n", .{});
            bad += 1;
        }
        return bad;
    }

    /// Validate, then pick `menu > item` like a click; false when missing or disabled.
    fn pick(menu: []const u8, item: []const u8) bool {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const sub = findSubmenu(menu) orelse return false;
        const ix = findItem(sub, item) orelse return false;
        sub.msg(void, "update", .{});
        if (sub.msg(id, "itemAtIndex:", .{ix}).msg(objc.BOOL, "isEnabled", .{}) != objc.YES) return false;
        std.debug.print("zeron smoke: shortcuts: pick menu {s} > {s}\n", .{ menu, item });
        sub.msg(void, "performActionForItemAtIndex:", .{ix});
        return true;
    }
} else struct {
    fn activate(_: *Window) void {}
    fn postKey(_: *Window, _: []const u8) void {}
    fn checkMenus() u32 {
        return 0;
    }
    fn pick(_: []const u8, _: []const u8) bool {
        return true;
    }
};

test "key codes for the table" {
    if (builtin.os.tag != .macos) return;
    try std.testing.expectEqual(@as(?u16, 11), mac.keyCode("b"));
    try std.testing.expectEqual(@as(?u16, 43), mac.keyCode(","));
    try std.testing.expectEqual(@as(?u16, 44), mac.keyCode("/"));
    try std.testing.expectEqual(@as(?u16, 18), mac.keyCode("1"));
}
