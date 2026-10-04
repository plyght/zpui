//! A gpui-style zpui app (`zig build hello`): a Counter view with a card, buttons with
//! hover/active styles, a focusable field, Geist text, an SVG icon and keybindings
//! (ctrl/cmd-= or ctrl/cmd-+ increments, tab moves focus, escape resets).
//!
//! Flags: `--frames N` quits after N presented frames; `--backend x11|wayland`.

const std = @import("std");
const zpui = @import("zpui");
const assets = @import("zeron_assets");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const rgb = zpui.rgb;
const sb = zpui.StyleBuilder.init;

const Increment = zpui.action("hello::Increment");
const Reset = zpui.action("hello::Reset");
const FocusNext = zpui.action("hello::FocusNext");
const FocusPrev = zpui.action("hello::FocusPrev");

fn hex(v: u32) zpui.Hsla {
    return rgb(v).toHsla();
}

const theme = struct {
    const bg = hex(0xf4f4f6);
    const card = hex(0xffffff);
    const border = hex(0xe4e4e7);
    const text = hex(0x18181b);
    const muted = hex(0x71717a);
    const accent = hex(0x4f46e5);
    const accent_hover = hex(0x6366f1);
    const accent_active = hex(0x4338ca);
    const subtle = hex(0xf4f4f5);
    const subtle_hover = hex(0xe4e4e7);
    const ring = hex(0xa5b4fc);
};

const Counter = struct {
    count: u32 = 0,
    last_key: []const u8 = "",
    last_key_buf: [32]u8 = undefined,
    root_focus: zpui.FocusHandle,
    field_focus: zpui.FocusHandle,

    fn init(window: *Window, cx: *Context(Counter)) Counter {
        const root_focus = cx.focusHandle();
        window.focus(root_focus); // key bindings dispatch from the focused element
        return .{ .root_focus = root_focus, .field_focus = cx.focusHandle().tabStop(true) };
    }

    pub fn deinit(self: *Counter, cx: *App) void {
        self.root_focus.release(cx);
        self.field_focus.release(cx);
    }

    fn increment(self: *Counter, _: *const Increment, _: *Window, cx: *Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }

    fn reset(self: *Counter, _: *const Reset, _: *Window, cx: *Context(Counter)) void {
        self.count = 0;
        cx.notify();
    }

    fn onIncrementClicked(self: *Counter, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }

    fn onResetClicked(self: *Counter, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Counter)) void {
        self.count = 0;
        cx.notify();
    }

    fn focusNext(_: *Counter, _: *const FocusNext, window: *Window, _: *Context(Counter)) void {
        window.focusNext();
    }

    fn focusPrev(_: *Counter, _: *const FocusPrev, window: *Window, _: *Context(Counter)) void {
        window.focusPrev();
    }

    fn onFieldKey(self: *Counter, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(Counter)) void {
        const name = ev.keystroke.key_char orelse ev.keystroke.key;
        const n = @min(name.len, self.last_key_buf.len);
        @memcpy(self.last_key_buf[0..n], name[0..n]);
        self.last_key = self.last_key_buf[0..n];
        cx.notify();
    }

    fn button(id: []const u8, label: []const u8, primary: bool) zpui.StatefulDiv {
        const base = div().id(id).flex().itemsCenter().justifyCenter().h(px(36)).px(px(16)).roundedLg()
            .textSm().fontWeight(500).cursorPointer();
        return if (primary)
            base.bg(theme.accent).textColor(zpui.color.white).shadowSm()
                .hover(sb.bg(theme.accent_hover)).active(sb.bg(theme.accent_active)).child(label)
        else
            base.bg(theme.subtle).textColor(theme.text).border1().borderColor(theme.border)
                .hover(sb.bg(theme.subtle_hover)).active(sb.bg(theme.border)).child(label);
    }

    pub fn render(self: *Counter, window: *Window, cx: *Context(Counter)) zpui.Div {
        const field_focused = self.field_focus.isFocused(window);
        return div()
            .trackFocus(self.root_focus)
            .keyContext("Counter")
            .onAction(Increment, cx.listener(Counter.increment))
            .onAction(Reset, cx.listener(Counter.reset))
            .onAction(FocusNext, cx.listener(Counter.focusNext))
            .onAction(FocusPrev, cx.listener(Counter.focusPrev))
            .sizeFull().flex().itemsCenter().justifyCenter()
            .bg(theme.bg).fontFamily("Geist").textColor(theme.text)
            .child(div()
                .w(px(380)).flex().flexCol().gap(px(20)).p(px(28))
                .bg(theme.card).roundedXl().border1().borderColor(theme.border).shadowLg()
                .child(div().flex().itemsCenter().gap(px(10))
                    .child(zpui.svg().source("sun", assets.Icon.sun.svg()).size(px(20)).textColor(theme.accent))
                    .child(div().text2xl().fontWeight(600).child("zpui"))
                    .child(div().textSm().textColor(theme.muted).child("· a gpui port in Zig")))
                .child(div().flex().flexCol().gap(px(2))
                    .child(div().textXs().fontWeight(500).textColor(theme.muted).child("COUNT"))
                    .child(div().textSize(px(56)).fontWeight(700).lineHeight(px(64)).child(zpui.fmt("{d}", .{self.count}))))
                .child(div().flex().gap(px(10))
                    .child(button("increment", "Increment", true).onClick(cx.listener(Counter.onIncrementClicked))
                        .tooltipWith(@as([]const u8, "Adds one · Ctrl + ="), Tooltip.build))
                    .child(button("reset", "Reset", false).onClick(cx.listener(Counter.onResetClicked))))
                .child(div().id("field").trackFocus(self.field_focus)
                    .onKeyDown(cx.listener(Counter.onFieldKey))
                    .h(px(40)).px(px(12)).flex().itemsCenter().roundedLg().border1()
                    .borderColor(theme.border).bg(theme.card).textSm().cursorText()
                    .focusStyle(sb.borderColor(theme.accent).shadow(&ring_shadow))
                    .textColor(if (field_focused) theme.text else theme.muted)
                    .child(if (field_focused)
                        (if (self.last_key.len > 0) zpui.fmt("Focused — last key: {s}", .{self.last_key}) else "Focused — type something")
                    else
                        "Click or press Tab to focus"))
                .child(div().textXs().textColor(theme.muted).child("Ctrl + = increments · Esc resets · Tab cycles focus")));
    }

    const ring_shadow = [_]zpui.BoxShadow{.{ .color = theme.ring, .offset = .zero, .spread_radius = 3 }};
};

/// A small view used as tooltip content.
const Tooltip = struct {
    text: []const u8,

    fn build(text: []const u8, _: *Window, cx: *App) zpui.Entity(Tooltip) {
        return cx.new(Tooltip, .{ .text = text }) catch @panic("OOM");
    }

    pub fn render(self: *Tooltip, _: *Window, _: *Context(Tooltip)) zpui.Div {
        return div().fontFamily("Geist").px(px(8)).py(px(4)).roundedMd().bg(hex(0x18181b)).shadowMd()
            .textXs().textColor(zpui.color.white).child(self.text);
    }
};

const Launch = struct {
    max_frames: ?u64,
};

fn onLaunch(launch: *Launch, app: *App) void {
    app.quit_when_last_window_closes = true;
    for ([_]assets.Font{ .geist_regular, .geist_medium, .geist_semi_bold, .geist_bold }) |f|
        app.addFont(f.info().data) catch |err| std.log.err("addFont: {t}", .{err});
    app.bindKeys(&.{
        .init("secondary-=", Increment{}, "Counter"),
        .init("secondary-+", Increment{}, "Counter"),
        .init("secondary-shift-=", Increment{}, "Counter"),
        .init("escape", Reset{}, "Counter"),
        .init("tab", FocusNext{}, null),
        .init("shift-tab", FocusPrev{}, null),
    }) catch @panic("bindKeys");
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 40, .y = 40 }, .size = .{ .width = 720, .height = 480 } },
        .titlebar = .{ .title = "zpui hello" },
        .app_id = "dev.zpui.hello",
    }, Counter, Counter.init, .{}) catch |err| {
        std.log.err("openWindow failed: {t}", .{err});
        app.quit();
        return;
    };
    if (launch.max_frames) |n| {
        // Quit after `n` vsync ticks (for scripted screenshots).
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
    var backend: ?zpui.linux_platform.BackendKind = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--frames") and i + 1 < argv.len) {
            i += 1;
            launch.max_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, argv[i], "--backend") and i + 1 < argv.len) {
            i += 1;
            backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, argv[i]);
        }
    }
    const plat = try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend });
    const app = try App.init(gpa, plat);
    defer app.deinit();
    app.run(&launch, onLaunch);
}
