//! `zig build changes-demo -- [options]`: the right-pane Changes / History
//! surfaces (`ui/changes`, `ui/history`) rendered from engine fixtures in a
//! 1600×1000 window with the pane at the reference position (x = 1080,
//! 520px wide) next to a stand-in left side, so screenshots line up with
//! `research/reference/{changes-pane,history-pane}-*.png`.
//!
//!   --pane changes|history|launcher   which surface (default changes)
//!   --fixtures DIR      engine export (chats.json, spaces.json, …; default
//!                       apps/zeron/fixtures/reference)
//!   --diffs FILE        WatchCheckoutDiffs frame (default
//!                       apps/zeron/src/ui/changes/testdata/checkout-diffs.json)
//!   --history FILE      ListGitHistory reply (default
//!                       apps/zeron/src/ui/history/testdata/aurora-history.json)
//!   --select NAME|ID    chat (seed-ids name or id; default backpressure)
//!   --light             Zeron Light (default dark)
//!   --loading           no diff data ("Preparing diff…")
//!   --split / --wrap    initial diff layout
//!   --scope-menu        open the scope dropdown
//!   --newtab-menu       open the right pane's new-tab menu
//!   --discard           open the discard confirmation
//!   --collapse N        fold file N
//!   --scroll PX         scroll the diff by PX
//!   --backdrop PNG      paint this screenshot's left 1080px as the left side
//!   --frames N          quit after N frames
//!   --backend x11|wayland

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("components/root.zig");
const fixtures_mod = @import("shell/fixtures.zig");
const changes = @import("changes/root.zig");
const history = @import("history/root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

const PaneKind = enum { changes, history, launcher };

const Options = struct {
    pane: PaneKind = .changes,
    fixtures: []const u8 = "apps/zeron/fixtures/reference",
    diffs: []const u8 = "apps/zeron/src/ui/changes/testdata/checkout-diffs.json",
    history: []const u8 = "apps/zeron/src/ui/history/testdata/aurora-history.json",
    select: []const u8 = "backpressure",
    light: bool = false,
    loading: bool = false,
    split: bool = false,
    wrap: bool = false,
    scope_menu: bool = false,
    newtab_menu: bool = false,
    discard: bool = false,
    collapse: ?usize = null,
    scroll: f32 = 0,
    backdrop: ?[]const u8 = null,
    frames: ?u64 = null,
    width: f32 = 1600,
    height: f32 = 1000,
};

const pane_left: f32 = 1080;

const Demo = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    state: ?Entity(model.AppState) = null,
    fixtures: ?*fixtures_mod.Fixtures = null,
    backdrop: ?[]u8 = null,
};

const Root = struct {
    opts: Options,
    backdrop: ?[]const u8,
    changes_pane: ?Entity(changes.ChangesPane) = null,
    history_pane: ?Entity(history.HistoryPane) = null,

    pub fn deinit(self: *Root, app: *App) void {
        if (self.changes_pane) |p| p.release(app);
        if (self.history_pane) |p| p.release(app);
    }

    fn init(opts: Options, backdrop: ?[]const u8, cp: ?Entity(changes.ChangesPane), hp: ?Entity(history.HistoryPane), window: *Window, cx: *Context(Root)) Root {
        _ = cx;
        window.setRemSize(16);
        return .{ .opts = opts, .backdrop = backdrop, .changes_pane = cp, .history_pane = hp };
    }

    fn leftSide(self: *Root, theme: *const zt.Theme) zpui.Div {
        var left = div().absolute().left(px(0)).top(px(0)).w(px(pane_left)).hFull().overflowHidden();
        if (self.backdrop) |bytes| {
            return left.child(zpui.img(zpui.ImageSource{ .image = .fromBytes(bytes) }).w(px(self.opts.width)).h(px(self.opts.height)).flexNone());
        }
        // Stand-in: glass sidebar column + main card with a title row.
        const side_bg = theme.wash(0.05);
        left = left.bg(theme.bg)
            .child(div().absolute().left(px(0)).top(px(0)).w(px(256)).hFull().bg(side_bg).borderR1().borderColor(theme.hairline(0.06)))
            .child(div().absolute().left(px(272)).top(px(12)).flex().itemsCenter().gap(px(6))
                .child(ui.icon.harness(.@"claude-code", 14, theme.text_muted, 1))
                .child(div().textSize(ui.rems(12)).fontWeight(500).textColor(theme.text.opacity(0.85)).child("Add backpressure to stream pipeline"))
                .child(div().textSize(ui.rems(12)).textColor(theme.text_muted.opacity(0.5)).child("aurora @ Workstation")));
        return left;
    }

    fn titlebar(self: *Root, theme: *const zt.Theme) zpui.Div {
        var strip = div().flex1().minW0().hFull().flex().flexRow().itemsCenter().gap(px(4)).overflowHidden();
        switch (self.opts.pane) {
            .changes => strip = strip.child(changes.tabs.surfaceTab("tab-0", .list, "Working tree", true, theme)),
            .history => strip = strip.child(changes.tabs.surfaceTab("tab-0", .list, "Working tree", false, theme))
                .child(changes.tabs.surfaceTab("tab-1", .git_branch, "History", true, theme)),
            .launcher => {},
        }
        if (self.opts.pane != .launcher) {
            var plus = changes.tabs.newTabButton(theme);
            if (self.opts.newtab_menu) {
                const pt = zpui.window.arena_mod.current().create(zt.Theme, theme.forPopup());
                plus = plus.bg(theme.wash(0.06)).child(ui.popover.anchoredBelow(changes.tabs.newTabMenu(pt)));
            }
            strip = strip.child(plus);
        }
        const icons = div().flexNone().flex().flexRow().itemsCenter().gap(px(4))
            .child(ui.button.headerIcon("expand-changes", .expand_arrows, "Expand panel", theme))
            .child(ui.button.headerIcon("toggle-files-panel", .file_tree, "Show files panel", theme))
            .child(ui.button.headerIconWith("toggle-changes", ui.icon.sidebarGlyph(1, true, 16, theme.text_muted), "Toggle right sidebar", theme));
        return div().absolute().left(px(0)).top(px(0)).right(px(0)).h(px(zt.layout.titlebar_height))
            .pt(px(zt.layout.titlebar_top_pad)).pl(px(7)).pr(px(6)).flex().flexRow().itemsCenter().gap(px(4))
            .child(strip).child(icons);
    }

    pub fn render(self: *Root, _: *Window, cx: *Context(Root)) zpui.Div {
        const theme = ui.theme.get(cx);
        const content: zpui.AnyElement = switch (self.opts.pane) {
            .changes => zpui.intoAnyElement(div().sizeFull().child(self.changes_pane.?)),
            .history => zpui.intoAnyElement(div().sizeFull().child(self.history_pane.?)),
            .launcher => zpui.intoAnyElement(changes.tabs.launcher(theme, true)),
        };
        const right = div().absolute().left(px(pane_left)).top(px(0)).right(px(0)).hFull()
            .bg(theme.panelBg()).borderL1().borderColor(theme.border)
            .child(div().sizeFull().pt(px(zt.layout.titlebar_height)).flex().flexCol().child(div().flex1().minH0().child(content)))
            .child(self.titlebar(theme));
        return div().sizeFull().relative().bg(theme.bg).fontFamily(theme.font_sans).textColor(theme.text)
            .child(self.leftSide(theme))
            .child(right);
    }
};

fn resolveChat(f: *fixtures_mod.Fixtures, io: std.Io, name: []const u8) []const u8 {
    const a = f.arena.allocator();
    const path = std.fs.path.join(a, &.{ f.dir, "seed-ids.json" }) catch return name;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return name;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return name;
    if (v != .object) return name;
    const chats = v.object.get("chats") orelse return name;
    if (chats != .object) return name;
    if (chats.object.get(name)) |id| if (id == .string) return id.string;
    return name;
}

fn readFile(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |err| {
        std.log.warn("cannot read {s}: {t}", .{ path, err });
        return null;
    };
}

fn onLaunch(d: *Demo, app: *App) void {
    app.quit_when_last_window_closes = true;
    for (std.enums.values(assets.Font)) |f| app.addFont(f.info().data) catch |err| std.log.err("addFont: {t}", .{err});
    actions.registerAll(app) catch |err| std.log.err("actions: {t}", .{err});
    var keymap_cfg: model.KeymapConfig = .{};
    actions.keymap.applyKeymap(app, &keymap_cfg, .enter) catch |err| std.log.err("keymap: {t}", .{err});
    model.settings_store.initMemory(app, d.io) catch {};
    const Set = struct {
        fn set(o: Options, s: *model.UiSettings, _: std.mem.Allocator) void {
            s.diffSplit = o.split;
            s.diffWrap = o.wrap;
        }
    };
    _ = model.settings_store.update(app, .immediate, d.opts, Set.set);

    const appearance: zt.Appearance = if (d.opts.light) .light else .dark;
    const theme = zt.Theme.forSelection(&zt.registry.builtin, .{
        .appearance = appearance,
        .variant_id = if (appearance == .dark) "zeron-dark" else "zeron-light",
        .surface = .frosted,
    });
    ui.theme.install(app, theme) catch @panic("theme");

    const state = app.newWith(model.AppState, model.AppState.init, .{ d.io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false } }) catch return;
    d.state = state;
    d.fixtures = fixtures_mod.load(d.gpa, d.io, d.opts.fixtures) catch null;
    if (d.fixtures) |f| {
        f.meta.selectedChat = resolveChat(f, d.io, d.opts.select);
        fixtures_mod.applyToState(f, d.io, app, state);
    }
    const a = if (d.fixtures) |f| f.arena.allocator() else d.gpa;

    var cp: ?Entity(changes.ChangesPane) = null;
    var hp: ?Entity(history.HistoryPane) = null;
    switch (d.opts.pane) {
        .changes => {
            const pane = app.newWith(changes.ChangesPane, changes.ChangesPane.init, .{state}) catch return;
            const store = pane.read(app).store;
            if (d.opts.loading) {
                store.update(app, changes.ChangesStore.setOffline, .{});
            } else if (readFile(d.io, a, d.opts.diffs)) |bytes| {
                changes.ChangesStore.applyFixture(store, app, bytes);
            }
            const Setup = struct {
                fn run(p: *changes.ChangesPane, o: Options, c: *Context(changes.ChangesPane)) void {
                    p.sync(c);
                    p.scope_menu_open = o.scope_menu;
                    if (o.collapse) |ix| {
                        if (p.foldPtr(ix)) |fold| fold.collapsed = true;
                        p.reflatten(false, c);
                    }
                    if (o.scroll != 0) p.list.scrollBy(o.scroll);
                    if (o.discard) p.openDiscard(c);
                }
            };
            pane.update(app, Setup.run, .{d.opts});
            cp = pane;
        },
        .history => {
            const pane = app.newWith(history.HistoryPane, history.HistoryPane.init, .{state}) catch return;
            const store = pane.read(app).store;
            if (readFile(d.io, a, d.opts.history)) |bytes| {
                const chat_cwd = if (state.read(app).workspace.read(app).selectedChatRow()) |c| c.cwd orelse "" else "";
                const key = std.fmt.allocPrint(a, "local|{s}", .{chat_cwd}) catch return;
                history.HistoryStore.applyFixture(store, app, key, bytes);
            }
            hp = pane;
        },
        .launcher => {},
    }

    if (d.opts.backdrop) |p| d.backdrop = readFile(d.io, d.gpa, p);

    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = d.opts.width, .height = d.opts.height } },
        .titlebar = .{ .title = "zeron right pane demo" },
        .app_id = "dev.zpui.changes-demo",
        .decorations = .server,
    }, Root, Root.init, .{ d.opts, d.backdrop, cp, hp }) catch |err| {
        std.log.err("openWindow failed: {t}", .{err});
        app.quit();
        return;
    };
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
        if (std.mem.eql(u8, arg, "--pane")) {
            opts.pane = std.meta.stringToEnum(PaneKind, next) orelse .changes;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fixtures")) {
            opts.fixtures = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--diffs")) {
            opts.diffs = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--history")) {
            opts.history = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--select")) {
            opts.select = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--light")) {
            opts.light = true;
        } else if (std.mem.eql(u8, arg, "--loading")) {
            opts.loading = true;
        } else if (std.mem.eql(u8, arg, "--split")) {
            opts.split = true;
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            opts.wrap = true;
        } else if (std.mem.eql(u8, arg, "--scope-menu")) {
            opts.scope_menu = true;
        } else if (std.mem.eql(u8, arg, "--newtab-menu")) {
            opts.newtab_menu = true;
        } else if (std.mem.eql(u8, arg, "--discard")) {
            opts.discard = true;
        } else if (std.mem.eql(u8, arg, "--collapse")) {
            opts.collapse = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scroll")) {
            opts.scroll = try std.fmt.parseFloat(f32, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--backdrop")) {
            opts.backdrop = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            opts.frames = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: changes-demo [--pane changes|history|launcher] [--light] [--loading] [--split] [--wrap] [--scope-menu] [--newtab-menu] [--discard] [--collapse N] [--scroll PX] [--backdrop PNG] [--fixtures DIR] [--history FILE] [--select NAME] [--frames N]\n", .{});
            return;
        }
    }
    const plat = try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend });
    const app = try App.init(gpa, plat);
    var demo: Demo = .{ .gpa = gpa, .io = init.io, .opts = opts };
    app.run(&demo, onLaunch);
    if (demo.state) |s| s.release(app);
    app.deinit();
    if (demo.fixtures) |f| {
        f.deinit();
        gpa.destroy(f);
    }
    if (demo.backdrop) |b| gpa.free(b);
}

test {
    _ = changes;
    _ = history;
}
