//! `zig build transcript-demo -- [options]`: render transcript fixtures in a
//! window with the real `TranscriptView` (offline `TranscriptStore`).
//!
//!   --fixture PATH     transcript JSON (default apps/zeron/fixtures/transcript-showcase.json);
//!                      a bare entry array, `{reset}`, `{frame}` or `{entries}`
//!   --stream           stream the last assistant entry in (30ms ticks)
//!   --stream-step N    bytes per tick (default 24)
//!   --light            Zeron Light
//!   --width W --height H   window size (default 1600x1000)
//!   --frames N         quit after N frames (scripted screenshots)
//!   --scroll-top       start scrolled to the top
//!   --open-groups      expand every tool group (and first chip details)
//!   --backend x11|wayland

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const tr = @import("zeron_ui_transcript");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const protocol = engine.protocol;

const Options = struct {
    fixture: []const u8 = "apps/zeron/fixtures/transcript-showcase.json",
    stream: bool = false,
    stream_step: usize = 24,
    light: bool = false,
    width: f32 = 1600,
    height: f32 = 1000,
    frames: ?u64 = null,
    scroll_top: bool = false,
    open_groups: bool = false,
    /// Reserve zeron's 256px sidebar (shell surface) so the transcript sits
    /// where it does in the real app (reference screenshots).
    sidebar: bool = true,
    /// Workspace root for inline-code file links.
    cwd: ?[]const u8 = null,
    /// Composer stack height the last row clears (the shell sets this).
    clearance: f32 = 113,
};

var theme_storage: zt.Theme = undefined;
var show_sidebar = true;
var open_all_details = false;

fn provideTheme(_: *App) *const zt.Theme {
    return &theme_storage;
}

const Demo = struct {
    io: std.Io,
    opts: Options,
    arena: std.heap.ArenaAllocator,
    engine: Entity(model.EngineState),
    store: Entity(model.TranscriptStore),
    tv: Entity(tr.TranscriptView),
    // Streaming state.
    full_text: []const u8 = "",
    entry_id: []const u8 = "",
    part_id: []const u8 = "",
    streamed: usize = 0,
    count: usize = 0,
    final_entry: ?protocol.SessionMessageEntry = null,
};

const Root = struct {
    tv: Entity(tr.TranscriptView),

    pub fn deinit(self: *Root, app: *App) void {
        self.tv.release(app);
    }

    fn init(tv: Entity(tr.TranscriptView), _: *Window, _: *Context(Root)) Root {
        return .{ .tv = tv };
    }

    pub fn render(self: *Root, _: *Window, _: *Context(Root)) zpui.Div {
        const theme = &theme_storage;
        var root = div().sizeFull().flex().flexRow().bg(theme.surface).fontFamily(theme.font_sans).textColor(theme.text);
        if (show_sidebar) root = root.child(div().w(px(256)).hFull().flexNone()
            .bg(if (theme.appearance == .dark) zpui.hsla(0, 0, 0.094, 1) else zpui.hsla(240.0 / 360.0, 0.04, 0.914, 1)));
        return root.child(div().flex1().minW0().hFull().child(self.tv));
    }
};

const StreamTick = struct {
    demo: *Demo,
    app: *App,

    pub fn finish(self: *StreamTick) void {
        const d = self.demo;
        if (d.streamed >= d.full_text.len) {
            if (d.final_entry) |e| {
                const ups = [_]protocol.TranscriptUpsert{.{ .after = null, .entry = e }};
                // Re-insert the completed entry at its position: remove + upsert after its predecessor.
                const store = d.store.read(self.app);
                var after: ?[]const u8 = null;
                var i: usize = 0;
                while (i < store.len()) : (i += 1) {
                    if (std.mem.eql(u8, store.entry(i).id, e.id)) break;
                    after = store.entry(i).id;
                }
                var up = ups;
                up[0].after = after;
                tr.applyFrame(d.store, .{ .delta = .{ .upsert = &up, .count = d.count } }, self.app);
            }
            return;
        }
        var end = @min(d.streamed + d.opts.stream_step, d.full_text.len);
        while (end < d.full_text.len and (d.full_text[end] & 0xC0) == 0x80) end += 1;
        const chunk = d.full_text[d.streamed..end];
        d.streamed = end;
        const app_ = [_]protocol.TextAppend{.{ .entry = d.entry_id, .part = d.part_id, .text = chunk, .len = end }};
        tr.applyFrame(d.store, .{ .delta = .{ .append = &app_, .count = d.count } }, self.app);
        var t = self.app.foregroundExecutor().timer(30 * std.time.ns_per_ms, StreamTick{ .demo = d, .app = self.app }) catch return;
        t.detach();
    }
};

fn onLaunch(d: *Demo, app: *App) void {
    app.quit_when_last_window_closes = true;
    for (std.enums.values(assets.Font)) |f| {
        app.addFont(f.info().data) catch |err| std.log.err("addFont: {t}", .{err});
    }
    theme_storage = zt.Theme.forSelection(&zt.registry.builtin, if (d.opts.light)
        .{ .appearance = .light, .variant_id = "zeron-light" }
    else
        .{ .appearance = .dark, .variant_id = "zeron-dark" });
    tr.view.theme_provider = provideTheme;
    show_sidebar = d.opts.sidebar;

    const a = d.arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(d.io, d.opts.fixture, a, .limited(64 << 20)) catch |err| {
        std.log.err("cannot read {s}: {t}", .{ d.opts.fixture, err });
        app.quit();
        return;
    };
    var entries = tr.parseFixture(a, bytes) catch |err| {
        std.log.err("cannot parse {s}: {t}", .{ d.opts.fixture, err });
        app.quit();
        return;
    };

    d.engine = app.newWith(model.EngineState, model.EngineState.init, .{ d.io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false } }) catch return;
    d.store = app.newWith(model.TranscriptStore, model.TranscriptStore.init, .{ d.engine, "demo-chat" }) catch return;
    d.count = entries.len;

    if (d.opts.stream) {
        // Find the last assistant entry with a text part: stream its last text part in.
        var ei = entries.len;
        while (ei > 0) {
            ei -= 1;
            if (entries[ei].role != .assistant) continue;
            const e = &entries[ei];
            var pi = e.parts.len;
            while (pi > 0) {
                pi -= 1;
                if (e.parts[pi] == .text) {
                    d.final_entry = e.*;
                    // Deep-ish copy of the parts so the live entry can differ.
                    const parts = a.alloc(protocol.MessagePart, pi + 1) catch return;
                    @memcpy(parts, e.parts[0 .. pi + 1]);
                    d.full_text = parts[pi].text.text;
                    parts[pi].text.text = "";
                    d.entry_id = e.id;
                    d.part_id = parts[pi].text.id;
                    var live = e.*;
                    live.parts = parts;
                    live.status = .streaming;
                    entries[ei] = live;
                    break;
                }
            }
            if (d.full_text.len > 0) break;
        }
        if (d.final_entry == null) d.opts.stream = false;
        // Drop entries after the streaming one (they arrive later in reality).
        if (d.opts.stream) {
            var cut = entries.len;
            for (entries, 0..) |e, i| if (std.mem.eql(u8, e.id, d.entry_id)) {
                cut = i + 1;
            };
            entries = entries[0..cut];
            d.count = cut;
        }
    }

    tr.loadEntries(d.store, entries, app) catch return;
    d.tv = app.newWith(tr.TranscriptView, tr.TranscriptView.initWithStore, .{d.store}) catch return;
    {
        // Mimic the shell: the transcript scrolls under the composer stack.
        const Clear = struct {
            fn run(v: *tr.TranscriptView, h: f32, _: *Context(tr.TranscriptView)) void {
                v.bottom_clearance = h;
            }
        };
        d.tv.update(app, Clear.run, .{d.opts.clearance});
    }
    if (d.opts.cwd) |cwd| {
        const SetRoot = struct {
            fn run(v: *tr.TranscriptView, root: []const u8, _: *Context(tr.TranscriptView)) void {
                v.setWorkspaceRoot(root);
            }
        };
        d.tv.update(app, SetRoot.run, .{cwd});
    }

    if (d.opts.scroll_top) {
        const Top = struct {
            fn run(v: *tr.TranscriptView, _: *Context(tr.TranscriptView)) void {
                v.start_at_top = true;
            }
        };
        d.tv.update(app, Top.run, .{});
    }
    if (d.opts.open_groups) {
        const Open = struct {
            fn run(v: *tr.TranscriptView, cx: *Context(tr.TranscriptView)) void {
                v.sync(cx);
                for (v.order.items) |r| if (r.kind == .tool_group) {
                    v.folds.put(v.gpa, r.key, .{ .open = true }) catch {};
                    for (r.kind.tool_group.tools, 0..) |t, ix| {
                        if (t.body != null and (t.body.? == .thought or open_all_details))
                            v.details.put(v.gpa, tr.tools.detailKey(r.key, ix), .{ .open = true }) catch {};
                    }
                };
                v.list.remeasure();
            }
        };
        d.tv.update(app, Open.run, .{});
    }
    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = d.opts.width, .height = d.opts.height } },
        .titlebar = .{ .title = "zeron transcript demo" },
        .app_id = "dev.zpui.transcript-demo",
    }, Root, Root.init, .{d.tv.retain(app)}) catch |err| {
        std.log.err("openWindow failed: {t}", .{err});
        app.quit();
        return;
    };
    if (d.opts.stream) {
        var t = app.foregroundExecutor().timer(400 * std.time.ns_per_ms, StreamTick{ .demo = d, .app = app }) catch return;
        t.detach();
    }
    if (d.opts.frames) |n| {
        const Quit = struct {
            left: u64,
            fn tick(self: *const @This(), win: *Window, ap: *App) void {
                if (self.left == 0) ap.quit() else {

                    win.refresh();
                    win.onNextFrame(@This(){ .left = self.left - 1 }, tick);
                }
            }
        };
        handle.window(app).?.onNextFrame(Quit{ .left = n }, Quit.tick);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var opts: Options = .{};
    var backend: ?zpui.linux_platform.BackendKind = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else "";
        if (std.mem.eql(u8, arg, "--fixture")) {
            opts.fixture = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            opts.stream = true;
        } else if (std.mem.eql(u8, arg, "--stream-step")) {
            opts.stream_step = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--light")) {
            opts.light = true;
        } else if (std.mem.eql(u8, arg, "--width")) {
            opts.width = try std.fmt.parseFloat(f32, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--height")) {
            opts.height = try std.fmt.parseFloat(f32, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            opts.frames = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scroll-top")) {
            opts.scroll_top = true;
        } else if (std.mem.eql(u8, arg, "--clearance")) {
            opts.clearance = try std.fmt.parseFloat(f32, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            opts.cwd = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-sidebar")) {
            opts.sidebar = false;
        } else if (std.mem.eql(u8, arg, "--open-details")) {
            opts.open_groups = true;
            open_all_details = true;
        } else if (std.mem.eql(u8, arg, "--open-groups")) {
            opts.open_groups = true;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: transcript-demo [--fixture PATH] [--stream] [--light] [--width W --height H] [--frames N] [--scroll-top] [--open-groups]\n", .{});
            return;
        }
    }
    const plat = try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend });
    const app = try App.init(gpa, plat);
    var demo: Demo = .{
        .io = init.io,
        .opts = opts,
        .arena = .init(gpa),
        .engine = undefined,
        .store = undefined,
        .tv = undefined,
    };
    defer demo.arena.deinit();
    app.run(&demo, onLaunch);
    app.deinit();
}
