//! `ZERON_SMOKE_NEW_CHAT=1` (macOS CI, with `--smoke-frames N` and fixtures): after the
//! frames, press a real ⌘N — an `NSEvent` posted to NSApp, so it takes AppKit's whole
//! key-equivalent path (window → view hierarchy → main menu) — with each of these
//! holding the keyboard, and require the new-chat canvas after each:
//!   terminal  the drawer's PTY terminal (focused when it opens);
//!   editor    a file tab in the right pane (`build.zig` of the working directory);
//!   browser   a Browser tab with its WKWebView made first responder
//!             (`ZERON_SMOKE_BROWSER_URL`; skipped without one);
//!   settings  Settings (⌘N must close it);
//!   composer  the composer's text input.
//! Logs each step; `PASS: zeron smoke: new chat` or `FAIL: zeron smoke: new chat ...`.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const shell_mod = @import("ui/shell/shell.zig");
const right_pane_mod = @import("ui/shell/right_pane.zig");
const rp_chats = @import("ui/shell/right_pane_chats.zig");
const prefs_mod = @import("ui/shell/prefs.zig");
const files = @import("ui/files/root.zig");
const browser = @import("ui/browser/root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Shell = shell_mod.Shell;

pub const Done = *const fn (app: *App, ok: bool) void;

const Step = enum { terminal, editor, browser, settings, composer, done };
const Phase = enum { setup, armed, sent };

var io_: std.Io = undefined;
var url_: ?[]const u8 = null;
var done_: Done = undefined;
var chat_buf: [128]u8 = undefined;
var chat_len: usize = 0;
var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
var root_len: usize = 0;
/// The step's Browser tab (owned by the right pane).
var browser_pane: ?zpui.Entity(browser.BrowserPane) = null;

/// Start the run (after the smoke's warm-up frames). `done` reports the verdict.
pub fn begin(io: std.Io, win: *Window, app: *App, browser_url: ?[]const u8, done: Done) void {
    io_ = io;
    url_ = browser_url;
    done_ = done;
    if (builtin.os.tag != .macos) return fail(app, "ZERON_SMOKE_NEW_CHAT is macOS only");
    const sh = shellOf(win, app) orelse return fail(app, "root view is not the shell");
    const sel = selected(sh, app) orelse return fail(app, "no selected chat (run with --fixtures)");
    if (sel.len > chat_buf.len) return fail(app, "chat id too long");
    @memcpy(chat_buf[0..sel.len], sel);
    chat_len = sel.len;
    root_len = std.Io.Dir.cwd().realPath(io, &root_buf) catch return fail(app, "cannot resolve the working directory");
    mac.activate(win);
    win.onNextFrame(Run{}, Run.tick);
}

const Run = struct {
    step: Step = .terminal,
    phase: Phase = .setup,
    wait: u32 = 0,
    /// Frames left for a browser page to load.
    load_left: u32 = 0,

    fn tick(self: *const Run, win: *Window, app: *App) void {
        var next = self.*;
        win.refresh();
        if (next.wait > 0) {
            next.wait -= 1;
            return win.onNextFrame(next, tick);
        }
        const sh = shellOf(win, app) orelse return fail(app, "the shell went away");
        switch (next.phase) {
            .setup => {
                if (next.step == .done) {
                    std.debug.print("PASS: zeron smoke: new chat (cmd-n from the terminal, editor, browser, settings and composer)\n", .{});
                    return done_(app, true);
                }
                reselect(sh, app);
                if (!setup(next.step, sh, win, app)) {
                    std.debug.print("zeron smoke: new chat: {t}: skipped\n", .{next.step});
                    next.step = @enumFromInt(@intFromEnum(next.step) + 1);
                    return win.onNextFrame(next, tick);
                }
                next.phase = .armed;
                next.wait = 30;
                next.load_left = 1200;
            },
            .armed => {
                if (next.step == .browser and !browser.pane.smoke_loaded.load(.acquire)) {
                    if (browser.pane.smoke_failed.load(.acquire)) return fail(app, "the browser page failed to load");
                    if (next.load_left == 0) return fail(app, "the browser page did not load in time");
                    next.load_left -= 1;
                    return win.onNextFrame(next, tick);
                }
                if (next.step == .browser) focusWebView(sh, win, app);
                if (selected(sh, app) == null) return fail(app, "the chat was deselected before cmd-n");
                std.debug.print("zeron smoke: new chat: {t}: {s}; sending cmd-n\n", .{ next.step, mac.responderInfo(win) });
                mac.postCmdN(win);
                next.phase = .sent;
                next.wait = 30;
            },
            .sent => {
                const s = sh.read(app);
                if (selected(sh, app) != null or s.settings_view != null) {
                    std.debug.print("FAIL: zeron smoke: new chat: cmd-n from the {t} did not show a new chat (selected={?s}, settings open={})\n", .{ next.step, selected(sh, app), s.settings_view != null });
                    return done_(app, false);
                }
                std.debug.print("zeron smoke: new chat: {t}: ok\n", .{next.step});
                teardown(next.step, sh, app);
                next.step = @enumFromInt(@intFromEnum(next.step) + 1);
                next.phase = .setup;
                next.wait = 5;
            },
        }
        win.onNextFrame(next, tick);
    }
};

fn setup(step: Step, sh: zpui.Entity(Shell), win: *Window, app: *App) bool {
    switch (step) {
        .terminal => {
            // The drawer opens a PTY tab and focuses it.
            prefs_mod.mut(app).terminal_open = true;
            notify(sh, app);
        },
        .editor => {
            const rp = sh.read(app).right_pane;
            var l = rp.lease(app);
            defer l.end();
            const t = l.value.current(&l.cx) orelse return false;
            if (t.files == null) t.files = l.cx.newWith(files.WorkspaceFiles, files.WorkspaceFiles.init, .{ io_, files.client.Source{ .local = root_buf[0..root_len] } }) catch return false;
            rp_chats.openFileAt(l.value, "build.zig", 1, 1, &l.cx);
            app.deferFn(win, focusEditorLater);
        },
        .browser => {
            const url = url_ orelse return false;
            browser.pane.smoke_loaded.store(false, .release);
            browser_pane = sh.read(app).right_pane.update(app, right_pane_mod.RightPane.addBrowser, .{ @as(?[]const u8, url), win });
            if (browser_pane == null) return false;
        },
        .settings => sh.update(app, Shell.openSettings, .{win}),
        .composer => {
            const c = sh.read(app).main.read(app).slots.composer_view;
            var l = c.lease(app);
            defer l.end();
            l.value.focusInput(win, &l.cx);
        },
        .done => {},
    }
    return true;
}

fn teardown(step: Step, sh: zpui.Entity(Shell), app: *App) void {
    if (step == .terminal) {
        prefs_mod.mut(app).terminal_open = false;
        notify(sh, app);
    }
}

fn focusEditorLater(win: *Window, app: *App) void {
    const sh = shellOf(win, app) orelse return;
    const ed = rp_chats.activeFileEditor(sh.read(app).right_pane.read(app), app) orelse return;
    var l = ed.lease(app);
    defer l.end();
    l.value.focusEditor(win);
}

/// Hand the keyboard to the page itself (AppKit first responder = the WKWebView).
fn focusWebView(_: zpui.Entity(Shell), win: *Window, app: *App) void {
    const pane = browser_pane orelse return;
    if (pane.read(app).native_view) |v| win.focusNativeView(v);
}

fn notify(sh: zpui.Entity(Shell), app: *App) void {
    sh.update(app, struct {
        fn f(_: *Shell, cx: *zpui.Context(Shell)) void {
            cx.notify();
        }
    }.f, .{});
}

fn reselect(sh: zpui.Entity(Shell), app: *App) void {
    const ws = sh.read(app).state.read(app).workspace;
    ws.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, chat_buf[0..chat_len])});
}

fn selected(sh: zpui.Entity(Shell), app: *App) ?[]const u8 {
    return sh.read(app).state.read(app).workspace.read(app).selected_chat;
}

fn shellOf(win: *Window, app: *App) ?zpui.Entity(Shell) {
    _ = app;
    const root = win.root orelse return null;
    return root.entity.downcast(Shell);
}

fn fail(app: *App, reason: []const u8) void {
    std.debug.print("FAIL: zeron smoke: new chat: {s}\n", .{reason});
    done_(app, false);
}

const mac = if (builtin.os.tag == .macos) struct {
    const m = zpui.mac_platform;
    const objc = m.objc_runtime;
    const ak = m.appkit;
    const id = objc.id;

    fn activate(win: *Window) void {
        const mw = m.MacWindow.fromWindow(win.platform_window);
        ak.sharedApp().msg(void, "activateIgnoringOtherApps:", .{objc.YES});
        mw.native_window.msg(void, "makeKeyAndOrderFront:", .{@as(?id, null)});
    }

    /// Queue a ⌘N key down + up (kVK_ANSI_N = 45) for the window, as the keyboard would.
    fn postCmdN(win: *Window) void {
        const mw = m.MacWindow.fromWindow(win.platform_window);
        activate(win);
        const app = ak.sharedApp();
        const num = mw.native_window.msg(isize, "windowNumber", .{});
        const now = ak.class("NSProcessInfo").msg(id, "processInfo", .{}).msg(f64, "systemUptime", .{});
        const n = ak.nsString("n");
        const types = [_]usize{ 10, 11 }; // key down, key up
        for (types, 0..) |ty, i| {
            const ev = ak.class("NSEvent").msg(?id, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
                ty, ak.NSPoint{ .x = 0, .y = 0 }, ak.NSEventModifierFlags.command, now + @as(f64, @floatFromInt(i)) * 0.01, num, @as(?id, null), n, n, objc.NO, @as(u16, 45),
            }) orelse return;
            app.msg(void, "postEvent:atStart:", .{ ev, objc.NO });
        }
    }

    var info_buf: [256]u8 = undefined;

    /// "key window: yes, first responder: WKWebView" for the log.
    fn responderInfo(win: *Window) []const u8 {
        const mw = m.MacWindow.fromWindow(win.platform_window);
        const key = mw.native_window.msg(objc.BOOL, "isKeyWindow", .{}) == objc.YES;
        const r = mw.native_window.msg(?id, "firstResponder", .{});
        const cls: []const u8 = if (r) |x| ak.stringBytes(x.msg(id, "className", .{})) else "nil";
        return std.fmt.bufPrint(&info_buf, "key window: {}, first responder: {s}", .{ key, cls }) catch "?";
    }
} else struct {
    fn activate(_: *Window) void {}
    fn postCmdN(_: *Window) void {}
    fn responderInfo(_: *Window) []const u8 {
        return "";
    }
};
