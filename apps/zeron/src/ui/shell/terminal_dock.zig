//! The terminal dock under the main column (zeron `terminal/panel.rs` +
//! `terminal/view.rs`), toggled with mod-j: a 40px tab bar (118px tabs with
//! the terminal glyph, label and close; `+`; collapse chevron) over a Geist
//! Mono 13/18 grid on the theme's terminal background.
//!
//! The Rust app streams its PTY from the engine (`SubscribeTerminal`); this
//! port runs the user's shell on a local PTY (`zeron_terminal.pty`) in the
//! chat's working directory and renders Ghostty's VT state through the
//! shared paint plan (`zeron_terminal.paint`).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const term = @import("zeron_terminal");
const ui = @import("../components/root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const Bounds = zpui.Bounds(f32);

pub const tab_bar_height: f32 = 40;
pub const tab_width: f32 = 118;
const font_size: f32 = 13;
const line_height: f32 = 18;
const padding: f32 = 12;

pub const Hide = struct {};

/// Local PTY support (`zeron_terminal.pty`: libc `forkpty`, Linux and macOS).
const has_pty = builtin.os.tag == .linux or builtin.os.tag.isDarwin();
const PtyT = if (has_pty) term.pty.Pty else void;

pub const TerminalDock = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    emu: *term.Emulator,
    pty: ?PtyT = null,
    focus: zpui.FocusHandle,
    poll_task: zpui.Task(void) = .none,
    cols: u16 = 80,
    rows: u16 = 12,
    exited: bool = false,
    cell_width: f32 = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    /// Draw the dock chrome (tab bar + top border); off for right-pane surfaces.
    chrome: bool = true,

    pub const Events = .{Hide};

    pub fn init(io: std.Io, cwd: ?[]const u8, window: *Window, cx: *Context(TerminalDock)) !TerminalDock {
        const gpa = cx.gpa();
        const emu = try term.Emulator.create(gpa, .{ .cols = 80, .rows = 12, .io = io });
        errdefer emu.destroy();
        var self: TerminalDock = .{ .gpa = gpa, .io = io, .emu = emu, .focus = cx.focusHandle() };
        self.applyPalette(cx);
        if (has_pty) {
            const shell_path: [:0]const u8 = blk: {
                const env = std.c.getenv("SHELL") orelse break :blk "/bin/bash";
                break :blk std.mem.span(env);
            };
            var cwd_z: ?[:0]u8 = null;
            defer if (cwd_z) |z| gpa.free(z);
            if (cwd) |d| cwd_z = gpa.dupeSentinel(u8, d, 0) catch null;
            self.pty = term.pty.Pty.spawn(&.{shell_path}, .{ .cols = 80, .rows = 12, .cwd = cwd_z }) catch null;
        }
        self.poll_task = try cx.timer(16 * std.time.ns_per_ms, onPoll);
        window.focus(self.focus);
        return self;
    }

    pub fn deinit(self: *TerminalDock, app: *App) void {
        self.poll_task.cancel();
        if (has_pty) if (self.pty) |*p| p.deinit();
        self.emu.destroy();
        self.focus.release(app);
    }

    fn applyPalette(self: *TerminalDock, cx: anytype) void {
        const theme = ui.theme.get(cx);
        var pal = term.Palette.fromTheme(theme.terminal, if (theme.appearance.isDark()) .dark else .light);
        const c = theme.cursor.toRgba();
        pal.cursor = .{ .r = to8(c.r), .g = to8(c.g), .b = to8(c.b) };
        self.emu.setPalette(&pal) catch {};
    }

    fn palette(cx: anytype) term.Palette {
        const theme = ui.theme.get(cx);
        var pal = term.Palette.fromTheme(theme.terminal, if (theme.appearance.isDark()) .dark else .light);
        const c = theme.cursor.toRgba();
        pal.cursor = .{ .r = to8(c.r), .g = to8(c.g), .b = to8(c.b) };
        return pal;
    }

    fn onPoll(self: *TerminalDock, cx: *Context(TerminalDock)) void {
        var changed = false;
        if (has_pty) if (self.pty) |*p| {
            var buf: [16 * 1024]u8 = undefined;
            var rounds: usize = 0;
            while (rounds < 16) : (rounds += 1) {
                const n = p.read(&buf, 0) catch null;
                const got = n orelse {
                    if (!self.exited) {
                        self.exited = true;
                        changed = true;
                    }
                    break;
                };
                if (got == 0) break;
                const reply = self.emu.feed(buf[0..got]);
                if (reply.len > 0) p.write(reply) catch {};
                changed = true;
            }
        };
        if (changed) cx.notify();
        self.poll_task = cx.timer(16 * std.time.ns_per_ms, onPoll) catch .none;
    }

    fn onKey(self: *TerminalDock, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(TerminalDock)) void {
        if (!has_pty) return;
        const p = if (self.pty) |*pp| pp else return;
        var buf: [64]u8 = undefined;
        const bytes = term.keys.encode(self.emu, term.keys.fromKeystroke(ev.keystroke), &buf) orelse return;
        self.emu.scrollToBottom();
        p.write(bytes) catch {};
        cx.stopPropagation();
        cx.notify();
    }

    fn onScroll(self: *TerminalDock, ev: *const zpui.input.ScrollWheelEvent, _: *Window, cx: *Context(TerminalDock)) void {
        const dy = switch (ev.delta) {
            .pixels => |d| d.y / line_height,
            .lines => |d| d.y,
        };
        const lines: i32 = @intFromFloat(@round(-dy * 3));
        if (lines != 0) {
            self.emu.scroll(lines);
            cx.notify();
        }
    }

    fn onFocusClick(self: *TerminalDock, _: *const zpui.input.MouseDownEvent, window: *Window, _: *Context(TerminalDock)) void {
        window.focus(self.focus);
    }

    fn onHide(_: *TerminalDock, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TerminalDock)) void {
        cx.emit(Hide{});
    }

    /// Grid painter: resizes the PTY to the box, then paints the plan.
    fn paintGrid(self: *TerminalDock, bounds: Bounds, window: *Window, app: *App) void {
        const pal = palette(app);
        if (self.cell_width == 0) {
            const runs = [_]zpui.text.TextRun{.{ .len = 1, .font = .{ .family = zt.typography.font_mono }, .color = zpui.color.white }};
            if (window.text_system.shapeLine("0", font_size, &runs, null)) |line| {
                self.cell_width = line.width();
                line.deinit(self.gpa);
            } else |_| self.cell_width = 7.8;
        }
        const cols_f = @floor((bounds.size.width - 2 * padding) / self.cell_width);
        const rows_f = @floor((bounds.size.height - 2 * padding) / line_height);
        const cols: u16 = @intFromFloat(@max(cols_f, 2));
        const rows: u16 = @intFromFloat(@max(rows_f, 1));
        if (cols != self.cols or rows != self.rows) {
            self.cols = cols;
            self.rows = rows;
            self.emu.resize(cols, rows) catch {};
            if (has_pty) if (self.pty) |*p| p.resize(cols, rows);
        }
        const snap = self.emu.snapshot() catch return;
        var plan = term.paint.build(self.gpa, snap, &pal) catch return;
        defer plan.deinit();
        const cw = self.cell_width;
        const origin = bounds.origin;
        const rect = struct {
            fn f(o: zpui.Point(f32), row: u16, col: u16, len: u16, w: f32) Bounds {
                return .{
                    .origin = .{ .x = o.x + padding + w * @as(f32, @floatFromInt(col)), .y = o.y + padding + line_height * @as(f32, @floatFromInt(row)) },
                    .size = .{ .width = w * @as(f32, @floatFromInt(len)), .height = line_height },
                };
            }
        }.f;
        for (plan.backgrounds) |q| window.paintQuad(zpui.fill(rect(origin, q.row, q.col, q.len, cw), hsla(q.color, 1)));
        for (plan.selections) |q| window.paintQuad(zpui.fill(rect(origin, q.row, q.col, q.len, cw), hsla(q.color, @as(f32, @floatFromInt(q.alpha)) / 255)));
        var runs: std.ArrayList(zpui.text.TextRun) = .empty;
        defer runs.deinit(self.gpa);
        const painter = window.glyphPainter();
        for (plan.segments) |seg| {
            runs.clearRetainingCapacity();
            for (seg.runs) |r| {
                const color = hsla(r.style.color, r.style.alpha);
                runs.append(self.gpa, .{
                    .len = r.len,
                    .font = .{
                        .family = zt.typography.font_mono,
                        .weight = if (r.style.bold) zpui.text.weight.bold else zpui.text.weight.normal,
                        .style = if (r.style.italic) .italic else .normal,
                    },
                    .color = color,
                    .underline = if (r.style.underline != .none) .{ .thickness = 1, .color = color, .wavy = r.style.underline == .curly } else null,
                    .strikethrough = if (r.style.strikethrough) .{ .thickness = 1, .color = color } else null,
                }) catch return;
            }
            const line = window.text_system.shapeLine(seg.text, font_size, runs.items, null) catch continue;
            defer line.deinit(self.gpa);
            const o = rect(origin, seg.row, seg.col, 1, cw).origin;
            line.paint(painter, o, line_height, .left, null) catch {};
        }
        if (plan.cursor) |cur| {
            const r = rect(origin, cur.row, cur.col, cur.width, cw);
            const c = hsla(cur.color, 1);
            switch (cur.style) {
                .block => window.paintQuad(zpui.fill(r, c)),
                .bar => window.paintQuad(zpui.fill(.{ .origin = r.origin, .size = .{ .width = 2, .height = r.size.height } }, c)),
                .underline => window.paintQuad(zpui.fill(.{ .origin = .{ .x = r.origin.x, .y = r.origin.y + r.size.height - 2 }, .size = .{ .width = r.size.width, .height = 2 } }, c)),
                .block_hollow => window.paintQuad(zpui.outline(r, c, .solid)),
            }
        }
    }

    pub fn render(self: *TerminalDock, _: *Window, cx: *Context(TerminalDock)) zpui.StatefulDiv {
        const theme = ui.theme.get(cx);
        const title: []const u8 = if (self.emu.title()) |t| t else "Terminal 1";
        const label = zpui.fmt("{s}", .{title});
        const tab = div().id("terminal-tab").w(px(tab_width)).h(px(28)).flexNone()
            .flex().flexRow().itemsCenter().gap(px(6)).pl(px(8)).pr(px(4)).rounded(px(8))
            .bg(theme.ink(0.08)).textSize(px(12)).textColor(theme.text).cursorPointer()
            .opacity(if (self.exited) 0.55 else 1)
            .child(ui.icon.of(.terminal, 16, theme.text.opacity(0.8)))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().child(label))
            .child(div().id("terminal-tab-close").size(px(20)).flexNone().flex().itemsCenter().justifyCenter()
                .rounded(px(6)).cursorPointer().hover(sb.bg(theme.ink(0.09)))
                .onClick(cx.listener(TerminalDock.onHide))
                .child(ui.icon.of(.close, 12, theme.text_muted.opacity(0.8))));
        const bar = div().id("terminal-tab-bar").h(px(tab_bar_height)).flexNone().flex().flexRow().itemsCenter()
            .gap(px(4)).pl(px(8)).pr(px(6)).borderB1().borderColor(theme.hairline(0.07))
            .child(tab)
            .child(div().id("terminal-new-tab").size(px(28)).flexNone().flex().itemsCenter().justifyCenter()
                .rounded(px(8)).cursorPointer().hover(sb.bg(theme.ink(0.05)))
                .tooltipWith(@as([]const u8, "New terminal"), ui.tooltip.build)
                .child(ui.icon.of(.plus, 16, theme.text_muted.opacity(0.6))))
            .child(div().flex1())
            .child(div().id("terminal-collapse").size(px(28)).flexNone().flex().itemsCenter().justifyCenter()
                .rounded(px(8)).cursorPointer().hover(sb.bg(theme.ink(0.05)))
                .tooltipWith(@as([]const u8, "Hide terminal"), ui.tooltip.build)
                .onClick(cx.listener(TerminalDock.onHide))
                .child(ui.icon.of(.alt_arrow_down, 13, theme.text_muted.opacity(0.55))));
        var root = div().id("terminal-dock").trackFocus(self.focus).keyContext("Terminal")
            .onKeyDown(cx.listener(TerminalDock.onKey))
            .sizeFull().flex().flexCol().bg(theme.terminal.background)
            .fontFamily(theme.font_sans);
        if (self.chrome) root = root.borderT1().borderColor(theme.border).child(bar);
        return root
            .child(div().id("terminal-body").flex1().minH0().relative().overflowHidden().cursorText()
                .onMouseDown(.left, cx.listener(TerminalDock.onFocusClick))
                .onScrollWheel(cx.listener(TerminalDock.onScroll))
                .child(zpui.canvas(self, TerminalDock.paintGrid).sizeFull()));
    }
};

/// The surface title (OSC title, else "Terminal").
pub fn surfaceTitle(self: *const TerminalDock) []const u8 {
    return self.emu.title() orelse "Terminal";
}

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn hsla(c: term.snapshot.Rgb, alpha: f32) zpui.Hsla {
    var h = zpui.rgb((@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b).toHsla();
    h.a = alpha;
    return h;
}
