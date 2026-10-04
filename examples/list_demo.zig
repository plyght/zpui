//! Virtualized list demo (`zig build list-demo`): a chat-like, bottom-aligned `list()` of
//! 10,000 variable-height messages (wrapped text) that follows the tail, new messages
//! appended every 2 s with a fade/slide entrance (`withAnimation`), an edge-faded scroll
//! region, an overlay scrollbar and a frosted composer panel over the content.
//!
//! Flags:
//!   --frames N       quit after N vsync ticks (scripted screenshots)
//!   --autoscroll     scroll up/down continuously and log frame timing
//!   --count N        number of initial messages (default 10000)
//!   --no-append      do not append messages over time
//!   --backend x11|wayland
//!
//! Logs (stderr) every 60 frames: items laid out / rendered / measured, the frame's CPU
//! build time (render → end of paint) and the average frame interval.

const std = @import("std");
const zpui = @import("zpui");
const assets = @import("zeron_assets");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;

const log = std.log.scoped(.list_demo);

fn hex(v: u32) zpui.Hsla {
    return zpui.rgb(v).toHsla();
}

const theme = struct {
    const bg = hex(0x0f1115);
    const panel = hex(0x161a21);
    const text = hex(0xe6e8ee);
    const muted = hex(0x8b93a7);
    const user_bubble = hex(0x2b3a67);
    const assistant_bubble = hex(0x1b2029);
    const accent = hex(0x7aa2ff);
    const border = hex(0x2a3040);
};

const words = [_][]const u8{
    "the",         "list",    "measures",    "only",    "what",      "is",     "visible", "and",
    "caches",      "heights", "in",          "a",       "balanced",  "tree",   "so",      "scrolling",
    "through",     "ten",     "thousand",    "rows",    "stays",     "smooth", "while",   "new",
    "messages",    "arrive",  "at",          "the",     "bottom",    "of",     "this",    "transcript",
    "zpui",        "renders", "with",        "vulkan",  "lavapipe",  "text",   "wraps",   "naturally",
    "virtualized", "logical", "offset",      "anchors", "content",   "when",   "items",   "are",
    "spliced",     "above",   "follow-tail", "keeps",   "chat",      "pinned", "edge",    "fade",
    "frosted",     "panel",   "blur",        "overlay", "scrollbar", "thumb",  "fades",   "idle",
};

const Message = struct {
    text: []const u8,
    user: bool,
};

const Demo = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,
    state: zpui.ListState,
    focus: zpui.FocusHandle,
    rng: std.Random.DefaultPrng,
    /// Messages at or after this index animate in.
    animate_from: usize,
    append: bool,
    autoscroll: bool,
    frost: bool,
    tick: zpui.Task(void) = .none,
    // Frame statistics.
    frame: u64 = 0,
    render_start_ns: u64 = 0,
    last_render_ns: u64 = 0,
    build_ns_sum: u64 = 0,
    build_ns_max: u64 = 0,
    interval_ns_sum: u64 = 0,
    interval_ns_max: u64 = 0,
    interval_count: u64 = 0,
    stats_frames: u64 = 0,
    last_build_ms: f32 = 0,
    fps: f32 = 0,
    autoscroll_dir: f32 = -1,
    autoscroll_frames: u32 = 0,

    const Args = struct { count: usize, append: bool, autoscroll: bool, frost: bool = true };

    fn init(args: Args, window: *Window, cx: *Context(Demo)) Demo {
        var self: Demo = .{
            .gpa = cx.gpa(),
            .state = zpui.ListState.init(cx.gpa(), 0, .bottom, 320),
            .focus = cx.focusHandle(),
            .rng = .init(0x5eed),
            .animate_from = args.count -| 6,
            .append = args.append,
            .autoscroll = args.autoscroll,
            .frost = args.frost,
        };
        window.focus(self.focus);
        for (0..args.count) |i| self.addMessage(i);
        // Height hints size the scrollbar before rows are measured; real heights replace them.
        self.state.resetWithUniformHeight(args.count, 110);
        self.state.setFollowMode(.tail);
        self.state.setScrollHandler(cx.listener(Demo.onScroll));
        if (args.append) self.tick = cx.timer(2 * std.time.ns_per_s, Demo.onTick) catch .none;
        return self;
    }

    pub fn deinit(self: *Demo, cx: *App) void {
        self.tick.cancel();
        for (self.messages.items) |m| self.gpa.free(m.text);
        self.messages.deinit(self.gpa);
        self.state.release();
        self.focus.release(cx);
    }

    fn addMessage(self: *Demo, i: usize) void {
        const r = self.rng.random();
        const user = r.uintLessThan(u8, 3) == 0;
        const n: usize = if (user) 3 + r.uintLessThan(usize, 18) else 6 + r.uintLessThan(usize, if (r.boolean()) 30 else 110);
        var buf: std.ArrayList(u8) = .empty;
        buf.print(self.gpa, "{d}: ", .{i}) catch @panic("OOM");
        for (0..n) |k| {
            if (k > 0) buf.append(self.gpa, ' ') catch @panic("OOM");
            buf.appendSlice(self.gpa, words[r.uintLessThan(usize, words.len)]) catch @panic("OOM");
        }
        buf.append(self.gpa, '.') catch @panic("OOM");
        self.messages.append(self.gpa, .{ .text = buf.toOwnedSlice(self.gpa) catch @panic("OOM"), .user = user }) catch @panic("OOM");
    }

    fn onTick(self: *Demo, cx: *Context(Demo)) void {
        const n = self.messages.items.len;
        self.addMessage(n);
        self.state.splice(.{ .start = n, .end = n }, 1);
        self.tick.detach();
        self.tick = cx.timer(2 * std.time.ns_per_s, Demo.onTick) catch .none;
        cx.notify();
    }

    fn onScroll(self: *Demo, ev: *const zpui.ListScrollEvent, _: *Window, cx: *Context(Demo)) void {
        _ = self;
        _ = ev;
        cx.notify();
    }

    fn renderRow(self: *Demo, ix: usize, _: *Window, _: *Context(Demo)) zpui.AnyElement {
        const m = self.messages.items[ix];
        const bubble = div()
            .flex().flexCol().gap(px(4)).px(px(14)).py(px(10)).roundedXl().maxW(px(560))
            .bg(if (m.user) theme.user_bubble else theme.assistant_bubble)
            .border1().borderColor(theme.border)
            .child(div().textXs().textColor(if (m.user) theme.accent else theme.muted).child(if (m.user) "you" else "assistant"))
            .child(div().textSm().lineHeight(px(20)).textColor(theme.text).child(m.text));
        const row = div().wFull().flex().px(px(28)).py(px(5)).relative()
            .when(m.user, zpui.Div.justifyEnd, .{})
            .child(bubble);
        if (ix < self.animate_from) return zpui.intoAnyElement(row);
        return zpui.intoAnyElement(zpui.withAnimation(row, .{ "in", ix }, zpui.Animation.ms(500).withEasing(zpui.easing.ease_out_expo), struct {
            fn f(el: zpui.Div, t: f32) zpui.Div {
                return el.opacity(t).top(px(10 * (1 - t)));
            }
        }.f));
    }

    fn recordPaintEnd(self: *Demo, _: zpui.Bounds(f32), _: *Window, cx: *App) void {
        const now = cx.executor.now();
        const build = now -| self.render_start_ns;
        self.build_ns_sum += build;
        self.build_ns_max = @max(self.build_ns_max, build);
        self.stats_frames += 1;
        if (self.stats_frames >= 60) {
            const n: f64 = @floatFromInt(self.stats_frames);
            const avg_build = @as(f64, @floatFromInt(self.build_ns_sum)) / n / 1e6;
            const avg_int = @as(f64, @floatFromInt(self.interval_ns_sum)) / @as(f64, @floatFromInt(@max(self.interval_count, 1))) / 1e6;
            self.last_build_ms = @floatCast(avg_build);
            self.fps = if (avg_int > 0) @floatCast(1000 / avg_int) else 0;
            log.info("frame {d}: laid out {d} items, rendered {d}, measured {d}/{d} total; build avg {d:.2} ms max {d:.2} ms; interval avg {d:.2} ms max {d:.2} ms ({d:.1} fps)", .{
                self.frame,                                          self.state.lastVisibleCount(),
                self.state.lastRenderedCount(),                      self.state.measuredCount(),
                self.state.itemCount(),                              avg_build,
                @as(f64, @floatFromInt(self.build_ns_max)) / 1e6,    avg_int,
                @as(f64, @floatFromInt(self.interval_ns_max)) / 1e6, self.fps,
            });
            self.build_ns_sum = 0;
            self.build_ns_max = 0;
            self.interval_ns_sum = 0;
            self.interval_ns_max = 0;
            self.interval_count = 0;
            self.stats_frames = 0;
        }
    }

    pub fn render(self: *Demo, window: *Window, cx: *Context(Demo)) zpui.Div {
        const now = cx.app.executor.now();
        if (self.last_render_ns != 0) {
            // Only count back-to-back frames (idle gaps are not frame time).
            const iv = now - self.last_render_ns;
            if (iv < 100 * std.time.ns_per_ms) {
                self.interval_ns_sum += iv;
                self.interval_ns_max = @max(self.interval_ns_max, iv);
                self.interval_count += 1;
            }
        }
        self.last_render_ns = now;
        self.render_start_ns = now;
        self.frame += 1;

        if (self.autoscroll) {
            self.state.scrollBy(self.autoscroll_dir * 37);
            self.autoscroll_frames += 1;
            if (self.autoscroll_frames % 240 == 0) self.autoscroll_dir = -self.autoscroll_dir;
            window.requestAnimationFrame();
        }

        const following = self.state.isFollowingTail();
        const stats = zpui.fmt("{d} messages · {d} laid out · {d} rendered · {d} measured · {d:.2} ms build · {d:.0} fps{s}", .{
            self.state.itemCount(),     self.state.lastVisibleCount(), self.state.lastRenderedCount(),
            self.state.measuredCount(), self.last_build_ms,            self.fps,
            if (following) " · following" else "",
        });

        const transcript = div().flex1().minH0().relative().wFull()
            .child(zpui.edgeFaded(28, true, true, zpui.list(self.state, cx, Demo.renderRow).sizeFull().pb(px(96)))
                .fadeOverflowY(self.state).bandBottom(36))
            .child(zpui.scrollbar(self.state).withStyle(.{
                .thumb = theme.text.opacity(0.30),
                .thumb_hover = theme.text.opacity(0.42),
                .thumb_active = theme.text.opacity(0.55),
            }))
            .child(div().absolute().bottom(px(18)).left(px(0)).right(px(0)).flex().justifyCenter()
            .child(zpui.frosted(16, 16, div()
            .w(px(620)).h(px(64)).rounded2xl().bg(theme.panel.opacity(0.4)).border1().borderColor(hex(0x3a4258))
            .shadowLg().flex().itemsCenter().justifyBetween().px(px(20))
            .child(div().textSm().textColor(theme.muted).child("Frosted composer · the transcript blurs underneath"))
            .child(div().px(px(10)).py(px(4)).roundedFull().bg(theme.accent.opacity(0.25)).textXs().textColor(theme.accent).child("send"))).enabled(self.frost)));

        return div()
            .trackFocus(self.focus)
            .sizeFull().flex().flexCol().bg(theme.bg).fontFamily("Geist").textColor(theme.text)
            .child(div().flexNone().h(px(44)).px(px(20)).flex().itemsCenter().justifyBetween()
                .borderB1().borderColor(theme.border)
                .child(div().textSm().fontWeight(600).child("zpui list demo"))
                .child(div().textXs().textColor(theme.muted).child(stats)))
            .child(transcript)
            .child(zpui.canvas(self, Demo.recordPaintEnd).absolute().size(px(0)));
    }
};

const Launch = struct {
    max_frames: ?u64,
    args: Demo.Args,
};

fn onLaunch(launch: *Launch, app: *App) void {
    app.quit_when_last_window_closes = true;
    for ([_]assets.Font{ .geist_regular, .geist_medium, .geist_semi_bold, .geist_bold }) |f|
        app.addFont(f.info().data) catch |err| log.err("addFont: {t}", .{err});
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 960, .height = 720 } },
        .titlebar = .{ .title = "zpui list demo" },
        .app_id = "dev.zpui.list-demo",
    }, Demo, Demo.init, .{launch.args}) catch |err| {
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
    var launch: Launch = .{ .max_frames = null, .args = .{ .count = 10_000, .append = true, .autoscroll = false } };
    var backend: ?zpui.linux_platform.BackendKind = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--frames") and i + 1 < argv.len) {
            i += 1;
            launch.max_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--count") and i + 1 < argv.len) {
            i += 1;
            launch.args.count = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--autoscroll")) {
            launch.args.autoscroll = true;
        } else if (std.mem.eql(u8, a, "--no-frost")) {
            launch.args.frost = false;
        } else if (std.mem.eql(u8, a, "--no-append")) {
            launch.args.append = false;
        } else if (std.mem.eql(u8, a, "--backend") and i + 1 < argv.len) {
            i += 1;
            backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, argv[i]);
        }
    }
    const plat = try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend });
    const app = try App.init(gpa, plat);
    defer app.deinit();
    app.run(&launch, onLaunch);
}
