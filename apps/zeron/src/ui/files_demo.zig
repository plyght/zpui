//! `zig build files-demo -- [options]`: the Files explorer (`ui/files`) and
//! the file editor (`ui/editor`) in a 1600×1000 window at the reference
//! positions — the right pane's surface host at x = 795 (519px, editor tabs
//! in its titlebar strip) and the explorer column at x = 1314 (286px) — so
//! screenshots line up with `research/reference/files-{editor,panel-with-
//! history}-*.png`. The workspace is a local directory (a scratch copy of
//! `apps/zeron/fixtures/files/aurora` by default) or a live engine chat.
//!
//!   --root DIR          workspace directory (default: fixtures/files/aurora,
//!                       copied to /tmp/zeron-files-demo first)
//!   --in-place          edit --root directly (no scratch copy)
//!   --git-status FILE   CheckoutGitStatus JSON (default: the aurora fixture;
//!                       `none` = run `git status` in the root)
//!   --open PATH         open this file in the editor (default src/stream.rs;
//!                       `none` = no editor surface)
//!   --expand DIRS       comma-separated directories to expand (default src)
//!   --select PATH       select a tree row
//!   --big MB            generate a MB-sized file `big.txt` and open it
//!   --line N            go to line N after opening
//!   --wrap              soft wrap on
//!   --find TEXT         open the find bar with TEXT
//!   --light             Zeron Light (default dark)
//!   --show-all          show hidden / ignored files
//!   --backdrop PNG      paint this screenshot left of the surfaces
//!   --backdrop-width PX how much of it (default 795; 1314 = explorer only)
//!   --engine PORT --chat ID   use a running engine's workspace for chat ID
//!   --frames N          quit after N frames
//!   --backend x11|wayland

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const md = @import("zeron_ui_markdown");
const ui = @import("components/root.zig");
const changes_tabs = @import("changes/tabs.zig");
pub const files = @import("files/root.zig");
pub const editor = @import("editor/root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const FilesPanel = files.FilesPanel;
const FileEditor = editor.FileEditor;
const WorkspaceFiles = files.WorkspaceFiles;

const Options = struct {
    root: []const u8 = "apps/zeron/fixtures/files/aurora",
    in_place: bool = false,
    git_status: ?[]const u8 = "apps/zeron/fixtures/files/aurora.git-status.json",
    open: ?[]const u8 = "src/stream.rs",
    expand: []const u8 = "src",
    select: ?[]const u8 = null,
    big_mb: ?usize = null,
    line: ?usize = null,
    wrap: bool = false,
    find: ?[]const u8 = null,
    light: bool = false,
    show_all: bool = false,
    backdrop: ?[]const u8 = null,
    backdrop_width: f32 = 795,
    engine_port: ?u16 = null,
    chat: ?[]const u8 = null,
    frames: ?u64 = null,
    width: f32 = 1600,
    height: f32 = 1000,
};

const pane_left: f32 = 795;
const panel_width: f32 = 286;
const scratch_root = "/tmp/zeron-files-demo";

const Demo = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    root: []const u8 = "",
    backdrop: ?[]u8 = null,
    engine: ?Entity(model.EngineState) = null,
};

const Root = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    backdrop: ?[]const u8,
    files_client: Entity(WorkspaceFiles),
    panel: Entity(FilesPanel),
    editors: std.ArrayList(Entity(FileEditor)) = .empty,
    active: usize = 0,
    subs: zpui.Subscriptions = .{},
    pending_expand: std.ArrayList([]const u8) = .empty,
    window_id: zpui.WindowId,
    focus_editor: bool = false,

    pub fn deinit(self: *Root, app: *App) void {
        self.subs.deinit(self.gpa);
        for (self.editors.items) |e| e.release(app);
        self.editors.deinit(self.gpa);
        self.pending_expand.deinit(self.gpa);
        self.panel.release(app);
        self.files_client.release(app);
    }

    fn init(opts: Options, backdrop: ?[]const u8, fc: Entity(WorkspaceFiles), window: *Window, cx: *Context(Root)) !Root {
        window.setRemSize(16);
        const panel = try cx.newWith(FilesPanel, FilesPanel.init, .{ fc, files.panel.Options{ .show_all_files = opts.show_all } });
        var self: Root = .{ .gpa = cx.gpa(), .opts = opts, .backdrop = backdrop, .files_client = fc.retain(cx), .panel = panel, .window_id = window.id };
        try self.subs.add(self.gpa, try cx.subscribe(panel, onOpenFile));
        try self.subs.add(self.gpa, try cx.subscribe(panel, onRenamed));
        try self.subs.add(self.gpa, try cx.subscribe(panel, onDeleted));
        var it = std.mem.tokenizeScalar(u8, opts.expand, ',');
        while (it.next()) |d| try self.pending_expand.append(self.gpa, d);
        if (opts.open) |path| self.openFile(path, cx);
        if (self.editors.items.len == 0) {
            const Fx = struct {
                fn f(p: *FilesPanel, w: *Window, _: *Context(FilesPanel)) void {
                    p.focusTree(w);
                }
            };
            panel.update(cx, Fx.f, .{window});
        }
        return self;
    }

    fn openFile(self: *Root, path: []const u8, cx: *Context(Root)) void {
        for (self.editors.items, 0..) |e, i| if (std.mem.eql(u8, e.read(cx).filePath(), path)) {
            self.active = i;
            cx.notify();
            return;
        };
        const ed = cx.newWith(FileEditor, FileEditor.init, .{ self.files_client, path, editor.view.Options{ .soft_wrap = self.opts.wrap } }) catch return;
        self.subs.add(self.gpa, cx.subscribe(ed, onEditorState) catch return) catch {};
        self.subs.add(self.gpa, cx.subscribe(ed, onReveal) catch return) catch {};
        self.editors.append(self.gpa, ed) catch return;
        self.active = self.editors.items.len - 1;
        // The shell reveals the active file in the explorer and focuses the editor.
        self.panel.update(cx, FilesPanel.revealFile, .{path});
        self.focus_editor = true;
        cx.notify();
    }

    fn onOpenFile(self: *Root, _: Entity(FilesPanel), ev: *const files.panel.OpenFile, cx: *Context(Root)) void {
        self.openFile(ev.path, cx);
    }

    fn onRenamed(self: *Root, _: Entity(FilesPanel), ev: *const files.panel.EntryRenamed, cx: *Context(Root)) void {
        for (self.editors.items) |e| {
            const p = e.read(cx).filePath();
            if (std.mem.eql(u8, p, ev.old_path)) {
                e.update(cx, FileEditor.setPath, .{ev.new_path});
            } else if (files.model.isDescendant(p, ev.old_path)) {
                const np = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ ev.new_path, p[ev.old_path.len..] }) catch continue;
                defer self.gpa.free(np);
                e.update(cx, FileEditor.setPath, .{np});
            }
        }
        cx.notify();
    }

    fn onDeleted(self: *Root, _: Entity(FilesPanel), ev: *const files.panel.EntryDeleted, cx: *Context(Root)) void {
        for (self.editors.items) |e| {
            const p = e.read(cx).filePath();
            if (std.mem.eql(u8, p, ev.path) or files.model.isDescendant(p, ev.path)) e.update(cx, FileEditor.markDeleted, .{});
        }
    }

    fn onEditorState(_: *Root, _: Entity(FileEditor), _: *const editor.view.StateChanged, cx: *Context(Root)) void {
        cx.notify();
    }

    fn onReveal(self: *Root, _: Entity(FileEditor), ev: *const editor.view.RevealFile, cx: *Context(Root)) void {
        self.panel.update(cx, FilesPanel.revealFile, .{ev.path});
    }

    fn onTabClick(self: *Root, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Root)) void {
        if (ix >= self.editors.items.len) return;
        self.active = ix;
        const ed = self.editors.items[ix];
        ed.update(cx, struct {
            fn f(e: *FileEditor, w: *Window, _: *Context(FileEditor)) void {
                e.focusEditor(w);
            }
        }.f, .{window});
        self.panel.update(cx, FilesPanel.revealFile, .{ed.read(cx).filePath()});
        cx.notify();
    }

    fn onTabClose(self: *Root, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Root)) void {
        if (ix >= self.editors.items.len) return;
        cx.stopPropagation();
        const ed = self.editors.orderedRemove(ix);
        ed.release(cx);
        if (self.active >= self.editors.items.len) self.active = self.editors.items.len -| 1;
        cx.notify();
    }

    /// Expand the requested directories once the tree has them.
    fn driveExpansion(self: *Root, cx: *Context(Root)) void {
        if (self.pending_expand.items.len == 0) return;
        const p = self.panel.read(cx);
        const dir = self.pending_expand.items[0];
        const n = p.tree.node(dir) orelse return;
        _ = n;
        const Fx = struct {
            fn f(panel: *FilesPanel, d: []const u8, c: *Context(FilesPanel)) void {
                if (panel.tree.isExpanded(d)) return;
                panel.revealFile(d, c);
                if (panel.tree.node(d)) |node| {
                    _ = panel.tree.expand(node.path);
                    panel.loadDirectory(node.path, false, c);
                    panel.tree.clearSelection();
                }
            }
        };
        self.panel.update(cx, Fx.f, .{dir});
        _ = self.pending_expand.orderedRemove(0);
        if (self.pending_expand.items.len == 0) if (self.opts.select) |s| self.panel.update(cx, FilesPanel.revealFile, .{s});
    }

    fn leftSide(self: *Root, theme: *const zt.Theme) zpui.Div {
        const w = self.opts.backdrop_width;
        var left = div().absolute().left(px(0)).top(px(0)).w(px(w)).hFull().overflowHidden();
        if (self.backdrop) |bytes| {
            return left.child(zpui.img(zpui.ImageSource{ .image = .fromBytes(bytes) }).w(px(self.opts.width)).h(px(self.opts.height)).flexNone());
        }
        left = left.bg(theme.bg)
            .child(div().absolute().left(px(0)).top(px(0)).w(px(256)).hFull().bg(theme.wash(0.05)).borderR1().borderColor(theme.hairline(0.06)))
            .child(div().absolute().left(px(272)).top(px(12)).flex().itemsCenter().gap(px(6))
            .child(ui.icon.harness(.@"claude-code", 14, theme.text_muted, 1))
            .child(div().textSize(ui.rems(12)).fontWeight(500).textColor(theme.text.opacity(0.85)).child("Add backpressure to stream pipeline"))
            .child(div().textSize(ui.rems(12)).textColor(theme.text_muted.opacity(0.5)).child("aurora @ Workstation")));
        return left;
    }

    fn fileTab(self: *Root, ix: usize, theme: *const zt.Theme, cx: *Context(Root)) zpui.StatefulDiv {
        const ed = self.editors.items[ix].read(cx);
        const active = ix == self.active;
        const group = "file-tab";
        var slot = div().id(.{ "file-tab-close", ix }).flexNone().size(px(18)).rounded(px(4)).relative()
            .hover(sb.bg(theme.wash(0.12))).onClick(cx.listenerWith(ix, onTabClose));
        if (ed.hasUnsavedChanges()) slot = slot.child(div().absolute().inset0().flex().itemsCenter().justifyCenter()
            .groupHover(group, sb.opacity(0)).child(div().size(px(6)).roundedFull().bg(theme.text_muted)));
        slot = slot.child(div().absolute().inset0().flex().itemsCenter().justifyCenter().opacity(0).groupHover(group, sb.opacity(1))
            .child(ui.icon.of(.close, 12, theme.text_muted)));
        var chip = div().id(.{ "file-tab", ix }).group(group).h(px(24)).w(px(changes_tabs.chip_width)).flexNone().px(px(4)).rounded(px(6))
            .flex().flexRow().itemsCenter().gap(px(3)).cursorPointer().onClick(cx.listenerWith(ix, onTabClick))
            .child(div().flexNone().size(px(18)).flex().itemsCenter().justifyCenter().child(md.file_icons.icon(ed.tabIcon(), theme, 12)))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(ui.rems(11.5))
            .textColor(if (active) theme.text else theme.text_muted).child(ed.tabTitle()))
            .child(slot);
        chip = if (active) chip.bg(theme.wash(0.10)) else chip.hover(sb.bg(theme.wash(0.06)));
        return chip;
    }

    fn paneTitlebar(self: *Root, theme: *const zt.Theme, cx: *Context(Root)) zpui.Div {
        var strip = div().flex1().minW0().hFull().flex().flexRow().itemsCenter().gap(px(4)).overflowHidden()
            .child(changes_tabs.surfaceTab("tab-wt", .list, "Working tree", false, theme))
            .child(changes_tabs.surfaceTab("tab-hist", .git_branch, "History", false, theme));
        for (0..self.editors.items.len) |i| strip = strip.child(self.fileTab(i, theme, cx));
        strip = strip.child(changes_tabs.newTabButton(theme));
        return div().absolute().left(px(0)).top(px(0)).right(px(0)).h(px(zt.layout.titlebar_height))
            .pt(px(zt.layout.titlebar_top_pad)).pl(px(7)).pr(px(6)).flex().flexRow().itemsCenter().gap(px(4))
            .child(strip)
            .child(ui.button.headerIcon("expand-pane", .expand_arrows, "Expand panel", theme));
    }

    fn panelTitlebar(_: *Root, theme: *const zt.Theme) zpui.Div {
        return div().absolute().left(px(0)).top(px(0)).right(px(0)).h(px(zt.layout.titlebar_height))
            .pt(px(zt.layout.titlebar_top_pad)).pr(px(6)).flex().flexRow().itemsCenter().justifyEnd().gap(px(4))
            .child(ui.button.headerIcon("toggle-files-panel", .file_tree, "Hide files panel", theme).bg(theme.wash(0.10)))
            .child(ui.button.headerIcon("toggle-right", .sidebar_minimalistic, "Toggle right sidebar", theme));
    }

    pub fn render(self: *Root, window: *Window, cx: *Context(Root)) zpui.Div {
        const theme = ui.theme.get(cx);
        self.driveExpansion(cx);
        if (self.focus_editor and self.editors.items.len > 0) {
            self.focus_editor = false;
            self.editors.items[self.active].update(cx, struct {
                fn f(e: *FileEditor, w: *Window, _: *Context(FileEditor)) void {
                    e.focusEditor(w);
                }
            }.f, .{window});
        }
        var root = div().sizeFull().relative().bg(theme.bg).fontFamily(theme.font_sans).textColor(theme.text)
            .child(self.leftSide(theme));
        const panel_left = self.opts.width - panel_width;
        if (self.editors.items.len > 0 and self.opts.backdrop_width < panel_left) {
            const content = self.editors.items[@min(self.active, self.editors.items.len - 1)];
            root = root.child(div().absolute().left(px(pane_left)).top(px(0)).w(px(panel_left - pane_left)).hFull()
                .bg(theme.panelBg())
                .child(div().sizeFull().pt(px(zt.layout.titlebar_height)).flex().flexCol().child(div().flex1().minH0().flex().flexCol().child(content)))
                .child(self.paneTitlebar(theme, cx))
                .child(div().absolute().left(px(0)).top(px(0)).w(px(1)).hFull().bg(theme.border)));
        }
        root = root.child(div().absolute().left(px(panel_left)).top(px(0)).w(px(panel_width)).hFull()
            .bg(theme.panelBg()).borderL1().borderColor(theme.border)
            .child(div().sizeFull().pt(px(zt.layout.titlebar_height)).child(self.panel))
            .child(self.panelTitlebar(theme)));
        return root;
    }
};

fn readFile(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |err| {
        std.log.warn("cannot read {s}: {t}", .{ path, err });
        return null;
    };
}

/// Recursive copy of `src` into `dst` (created).
fn copyTree(io: std.Io, gpa: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dst);
    var dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const s = try std.fs.path.join(gpa, &.{ src, e.name });
        defer gpa.free(s);
        const d = try std.fs.path.join(gpa, &.{ dst, e.name });
        defer gpa.free(d);
        switch (e.kind) {
            .directory => try copyTree(io, gpa, s, d),
            .file => {
                const bytes = try cwd.readFileAlloc(io, s, gpa, .limited(256 << 20));
                defer gpa.free(bytes);
                try cwd.writeFile(io, .{ .sub_path = d, .data = bytes });
            },
            else => {},
        }
    }
}

fn writeBigFile(io: std.Io, gpa: std.mem.Allocator, root: []const u8, mb: usize) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var line: usize = 0;
    const words = [_][]const u8{ "fn", "let", "stream", "buffer", "pipeline", "capacity", "yield", "await", "high_water", "events", "render", "parts" };
    while (buf.items.len < mb * 1024 * 1024) : (line += 1) {
        buf.print(gpa, "{d:0>7} ", .{line + 1}) catch return;
        for (0..(line % 9) + 3) |k| {
            buf.appendSlice(gpa, words[(line * 7 + k * 3) % words.len]) catch return;
            buf.append(gpa, ' ') catch return;
        }
        buf.appendSlice(gpa, "// generated line for scrolling a large file\n") catch return;
    }
    const path = std.fs.path.join(gpa, &.{ root, "big.txt" }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch |err| std.log.err("big file: {t}", .{err});
}

fn onLaunch(d: *Demo, app: *App) void {
    app.quit_when_last_window_closes = true;
    for (std.enums.values(assets.Font)) |f| app.addFont(f.info().data) catch |err| std.log.err("addFont: {t}", .{err});
    actions.registerAll(app) catch |err| std.log.err("actions: {t}", .{err});
    var keymap_cfg: model.KeymapConfig = .{};
    actions.keymap.applyKeymap(app, &keymap_cfg, .enter) catch |err| std.log.err("keymap: {t}", .{err});
    editor.actions.bindDefaults(app) catch |err| std.log.err("editor keymap: {t}", .{err});
    model.settings_store.initMemory(app, d.io) catch {};

    const appearance: zt.Appearance = if (d.opts.light) .light else .dark;
    const theme = zt.Theme.forSelection(&zt.registry.builtin, .{
        .appearance = appearance,
        .variant_id = if (appearance == .dark) "zeron-dark" else "zeron-light",
        .surface = .frosted,
    });
    ui.theme.install(app, theme) catch @panic("theme");

    const source: files.client.Source = if (d.opts.engine_port) |port| blk: {
        const engine = app.newWith(model.EngineState, model.EngineState.init, .{ d.io, model.engine_state.Config{ .port = port, .zeron_path = null } }) catch return;
        d.engine = engine;
        break :blk .{ .engine = .{ .state = engine, .target = .{ .chat_id = d.opts.chat } } };
    } else .{ .local = d.root };
    const fc = app.newWith(WorkspaceFiles, WorkspaceFiles.init, .{ d.io, source }) catch return;
    defer fc.release(app);
    if (d.opts.engine_port == null) if (d.opts.git_status) |gs| {
        if (!std.mem.eql(u8, gs, "none")) if (readFile(d.io, d.gpa, gs)) |bytes| {
            defer d.gpa.free(bytes);
            fc.update(app, WorkspaceFiles.setGitStatusJson, .{bytes});
        };
    };

    if (d.opts.backdrop) |p| d.backdrop = readFile(d.io, d.gpa, p);
    var opts = d.opts;
    if (opts.big_mb) |mb| {
        writeBigFile(d.io, d.gpa, d.root, mb);
        opts.open = "big.txt";
    }
    if (opts.open) |o| if (std.mem.eql(u8, o, "none")) {
        opts.open = null;
    };

    const handle = app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = opts.width, .height = opts.height } },
        .titlebar = .{ .title = "zeron files demo" },
        .app_id = "dev.zpui.files-demo",
        .decorations = .server,
    }, Root, Root.init, .{ opts, d.backdrop, fc }) catch |err| {
        std.log.err("openWindow failed: {t}", .{err});
        app.quit();
        return;
    };
    if (opts.line != null or opts.find != null) {
        const Later = struct {
            line: ?usize,
            find: ?[]const u8,
            fn run(self: *const @This(), win: *Window, ap: *App) void {
                const h = zpui.WindowHandle(Root){ .id = win.id };
                const r = h.rootView(ap) orelse return;
                const rr = r.read(ap);
                if (rr.editors.items.len == 0) return;
                const ed = rr.editors.items[rr.active];
                if (ed.read(ap).phase == .loading) {
                    win.onNextFrame(self.*, run);
                    win.refresh();
                    return;
                }
                if (self.line) |l| ed.update(ap, FileEditor.goToLine, .{ l, null });
                if (self.find) |f| ed.update(ap, FileEditor.findText, .{ f, win });
            }
        };
        handle.window(app).?.onNextFrame(Later{ .line = opts.line, .find = opts.find }, Later.run);
    }
    if (opts.frames) |n| {
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
        if (std.mem.eql(u8, arg, "--root")) {
            opts.root = next;
            opts.git_status = null;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--in-place")) {
            opts.in_place = true;
        } else if (std.mem.eql(u8, arg, "--git-status")) {
            opts.git_status = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--open")) {
            opts.open = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--expand")) {
            opts.expand = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--select")) {
            opts.select = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--big")) {
            opts.big_mb = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--line")) {
            opts.line = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--find")) {
            opts.find = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            opts.wrap = true;
        } else if (std.mem.eql(u8, arg, "--light")) {
            opts.light = true;
        } else if (std.mem.eql(u8, arg, "--show-all")) {
            opts.show_all = true;
        } else if (std.mem.eql(u8, arg, "--backdrop")) {
            opts.backdrop = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--backdrop-width")) {
            opts.backdrop_width = try std.fmt.parseFloat(f32, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            opts.engine_port = try std.fmt.parseInt(u16, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--chat")) {
            opts.chat = next;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            opts.frames = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, next);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: files-demo [--root DIR] [--in-place] [--git-status FILE|none] [--open PATH|none] [--expand DIRS] [--select PATH] [--big MB] [--line N] [--wrap] [--find TEXT] [--light] [--show-all] [--backdrop PNG] [--backdrop-width PX] [--engine PORT --chat ID] [--frames N] [--backend x11|wayland]\n", .{});
            return;
        }
    }
    var demo: Demo = .{ .gpa = gpa, .io = init.io, .opts = opts };
    var root_buf: [4096]u8 = undefined;
    if (opts.engine_port == null) {
        var root: []const u8 = opts.root;
        if (!opts.in_place) {
            const dst = scratch_root ++ "/aurora";
            std.Io.Dir.cwd().deleteTree(init.io, scratch_root) catch {};
            copyTree(init.io, gpa, opts.root, dst) catch |err| {
                std.log.err("cannot copy {s} to {s}: {t}", .{ opts.root, dst, err });
                return err;
            };
            root = dst;
        }
        const n = std.Io.Dir.cwd().realPathFile(init.io, root, &root_buf) catch root.len;
        demo.root = if (n == root.len and !std.mem.startsWith(u8, root, "/")) root else root_buf[0..n];
    }
    const plat = try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend });
    const app = try App.init(gpa, plat);
    app.run(&demo, onLaunch);
    if (demo.engine) |e| e.release(app);
    app.deinit();
    if (demo.backdrop) |b| gpa.free(b);
}

test {
    _ = files;
    _ = editor;
}
