//! Appearance → Theme library (zeron `theme_library.rs` + `appearance.rs`
//! `open_import` / `compile_import` / `finish_import` /
//! `render_import_dialog` / `render_review_dialog` /
//! `render_theme_library_rows`): import a VS Code theme file, `package.json`
//! or extension folder as a snapshot or a linked source, then Reload /
//! Reveal / Review / Duplicate as editable / Unlink / Remove. The library
//! lives in `{data_dir}/theme-library.json` (shared with the Rust app) and its
//! families join the light/dark theme dropdowns through `registry.active()`.
//!
//! ```zig
//! theme_library.init(app, io, data_dir, true); // boot: load + install into the registry
//! theme_library.openImport(view, cx);      // "Add theme"
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");
const prompts = @import("file_prompts.zig");

const App = zpui.App;
const Context = zpui.Context;
const Window = zpui.Window;
const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const library = zt.library;
const vscode = zt.vscode;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;
const sb = zpui.StyleBuilder.init;

// ---- the app-wide library ------------------------------------------------------------

/// `ThemeLibraryState`.
pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Empty: in-memory (fixture runs) — mutations are not persisted.
    data_dir: []u8,
    lib: library.Library,
    load_warning: ?[]u8 = null,

    pub fn deinit(self: *State, _: *App) void {
        zt.registry.setCustom(&.{});
        self.lib.deinit();
        self.gpa.free(self.data_dir);
        if (self.load_warning) |m| self.gpa.free(m);
    }
};

fn stateMut(app: *App) ?*State {
    return @constCast(app.tryGlobal(State) orelse return null);
}

/// Load `{data_dir}/theme-library.json` and install its families
/// (`theme_library::init`). A load failure keeps an empty library + warning.
/// `persist = false` (fixture runs) loads but never writes back.
pub fn init(app: *App, io: std.Io, data_dir: []const u8, persist: bool) void {
    var diag: vscode.Diagnostic = .{};
    var warning: ?[]u8 = null;
    var lib = library.load(app.gpa, io, data_dir, &diag) catch blk: {
        warning = app.gpa.dupe(u8, diag.message()) catch null;
        break :blk library.Library.init(app.gpa) catch return;
    };
    lib.installRuntime();
    app.setGlobal(State{ .gpa = app.gpa, .io = io, .data_dir = app.gpa.dupe(u8, if (persist) data_dir else "") catch @constCast(""), .lib = lib, .load_warning = warning }) catch {
        lib.deinit();
        zt.registry.setCustom(&.{});
    };
}

/// The library global; an in-memory (unsaved) one when boot installed none (fixtures, tests).
fn ensure(app: *App) ?*State {
    if (stateMut(app)) |s| return s;
    store.ensure(app);
    const settings = app.tryGlobal(model.SettingsStore) orelse return null;
    var lib = library.Library.init(app.gpa) catch return null;
    const dir = app.gpa.dupe(u8, "") catch {
        lib.deinit();
        return null;
    };
    app.setGlobal(State{ .gpa = app.gpa, .io = settings.io, .data_dir = dir, .lib = lib }) catch return null;
    return stateMut(app);
}

pub fn entries(app: *App) []const library.Entry {
    const s = app.tryGlobal(State) orelse return &.{};
    return s.lib.entries;
}

pub fn loadWarning(app: *App) ?[]const u8 {
    const s = app.tryGlobal(State) orelse return null;
    return s.load_warning;
}

/// `persist_and_activate` + `reconcile_and_refresh`; restores the previous
/// entries when the save fails.
fn commit(app: *App, s: *State, previous: []const library.Entry, diag: *vscode.Diagnostic) bool {
    if (s.data_dir.len > 0) s.lib.save(s.io, s.data_dir, diag) catch {
        const msg = std.fmt.allocPrint(app.gpa, "could not save custom theme library: {s}", .{diag.message()}) catch "";
        defer if (msg.len > 0) app.gpa.free(msg);
        diag.set("{s}", .{msg});
        s.lib.entries = previous;
        return false;
    };
    s.lib.installRuntime();
    if (s.load_warning) |m| s.gpa.free(m);
    s.load_warning = null;
    reconcile(app);
    return true;
}

/// A selected variant that disappeared falls back to the first of its appearance.
fn reconcile(app: *App) void {
    const reg = zt.registry.active();
    const sel = store.current(app).theme.theme_selection;
    for (zt.Appearance.all) |ap| {
        if (reg.variant(sel.variantId(ap)) != null) continue;
        var it = reg.variantsFor(ap);
        const fallback = it.next() orelse continue;
        const Set = struct {
            fn f(c: struct { zt.Appearance, []const u8 }, st: *model.UiSettings, a: std.mem.Allocator) void {
                st.theme.theme_selection.setVariant(c[0], a.dupe(u8, c[1]) catch return);
            }
        };
        store.update(app, .immediate, .{ ap, fallback.id }, Set.f);
    }
    store.applyTheme(app);
}

/// `theme_library::install`; returns the entry id or an error message in `diag`.
pub fn install(app: *App, compilation: *const vscode.SourceCompilation, selected: []const []const u8, mode: library.InstallMode, diag: *vscode.Diagnostic) ?[]const u8 {
    const s = ensure(app) orelse {
        diag.set("custom theme library is not initialized", .{});
        return null;
    };
    const previous = s.lib.entries;
    const id = s.lib.install(compilation, selected, mode, diag) catch {
        s.lib.entries = previous;
        return null;
    };
    if (!commit(app, s, previous, diag)) return null;
    return id;
}

pub const Op = enum { reload, unlink, duplicate, remove, reveal };

/// Run a library row action; returns an error message (arena-free) on failure.
pub fn run(app: *App, op: Op, id: []const u8, diag: *vscode.Diagnostic) bool {
    const s = ensure(app) orelse {
        diag.set("custom theme library is not initialized", .{});
        return false;
    };
    const previous = s.lib.entries;
    switch (op) {
        .reveal => {
            const e = s.lib.entry(id) orelse {
                diag.set("theme source has no location to reveal", .{});
                return false;
            };
            const path = e.source.path() orelse {
                diag.set("theme source has no location to reveal", .{});
                return false;
            };
            app.platform.vtable.revealPath(app.platform.ptr, path);
            return true;
        },
        .reload => {
            // Reload failures persist the warning but keep the last good family.
            const ok = if (s.lib.reload(s.gpa, s.io, id, diag)) true else |_| false;
            var save_diag: vscode.Diagnostic = .{};
            if (!commit(app, s, previous, &save_diag)) {
                diag.* = save_diag;
                return false;
            }
            return ok;
        },
        .unlink => s.lib.unlink(id, diag) catch return false,
        .duplicate => {
            if (s.data_dir.len == 0) {
                diag.set("custom theme library is not initialized", .{});
                return false;
            }
            _ = s.lib.duplicateAsEditable(s.io, id, s.data_dir, diag) catch {
                s.lib.entries = previous;
                return false;
            };
        },
        .remove => if (!s.lib.remove(id)) {
            diag.set("unknown custom theme `{s}`", .{id});
            return false;
        },
    }
    return commit(app, s, previous, diag);
}

// ---- the import dialog -----------------------------------------------------------------

pub const ImportDialog = struct {
    input: zpui.Entity(input.TextInput),
    sub: zpui.Subscription,
    focus_pending: bool = true,
    mode: library.InstallMode = .snapshot,
    compilation: ?vscode.Owned(vscode.SourceCompilation) = null,
    /// Selected variant ids (owned).
    selected: std.ArrayList([]u8) = .empty,
    review_variant: ?[]u8 = null,
    err: ?[]u8 = null,

    pub fn deinit(self: *ImportDialog, gpa: std.mem.Allocator, app: *App) void {
        self.sub.deinit();
        self.input.release(app);
        self.clearCompilation(gpa);
        self.selected.deinit(gpa);
        if (self.err) |e| gpa.free(e);
    }

    fn clearCompilation(self: *ImportDialog, gpa: std.mem.Allocator) void {
        if (self.compilation) |*c| c.deinit();
        self.compilation = null;
        for (self.selected.items) |s| gpa.free(s);
        self.selected.clearRetainingCapacity();
        if (self.review_variant) |r| gpa.free(r);
        self.review_variant = null;
    }

    fn setErr(self: *ImportDialog, gpa: std.mem.Allocator, msg: ?[]const u8) void {
        if (self.err) |e| gpa.free(e);
        self.err = if (msg) |m| gpa.dupe(u8, m) catch null else null;
    }

    fn isSelected(self: *const ImportDialog, id: []const u8) ?usize {
        for (self.selected.items, 0..) |s, i| if (std.mem.eql(u8, s, id)) return i;
        return null;
    }
};

/// "Add theme" (`open_import`).
pub fn openImport(v: *SettingsView, cx: *Context(SettingsView)) void {
    closeImport(v, cx);
    const theme = ui.theme.get(cx).forPopup();
    const field = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
        .placeholder = "Theme file, package.json, or extension folder",
        .key_context = "PaletteSearch",
        .single_line = true,
        .edge_fade = false,
        .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
    }}) catch return;
    const sub = cx.subscribe(field, onInput) catch {
        field.release(cx.app);
        return;
    };
    v.import = .{ .input = field, .sub = sub };
    cx.notify();
}

pub fn closeImport(v: *SettingsView, cx: *Context(SettingsView)) void {
    if (v.import) |*d| d.deinit(v.gpa, cx.app);
    v.import = null;
    cx.notify();
}

fn onInput(v: *SettingsView, _: zpui.Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(SettingsView)) void {
    const d = if (v.import) |*x| x else return;
    switch (ev.*) {
        .edited => {
            // Editing the source invalidates an analysis of a different path.
            const text = std.mem.trim(u8, d.input.read(cx).text(), " \t\r\n");
            if (d.compilation) |c| if (!std.mem.eql(u8, c.value.path, text)) {
                d.clearCompilation(v.gpa);
                d.setErr(v.gpa, null);
                cx.notify();
            };
        },
        .submitted => submit(v, cx),
        .escape => closeImport(v, cx),
        else => {},
    }
}

/// Enter / the footer action: analyze first, then import.
pub fn submit(v: *SettingsView, cx: *Context(SettingsView)) void {
    const d = v.import orelse return;
    if (d.compilation != null) finishImport(v, cx) else compileImport(v, cx);
}

/// `source_name`: the file stem (the folder for a package.json).
pub fn sourceName(path: []const u8) []const u8 {
    const p = if (std.mem.eql(u8, std.fs.path.basename(path), "package.json")) (std.fs.path.dirname(path) orelse path) else path;
    const stem = std.fs.path.stem(p);
    return if (stem.len == 0) "Custom theme" else stem;
}

/// `compile_import`.
pub fn compileImport(v: *SettingsView, cx: *Context(SettingsView)) void {
    const d = if (v.import) |*x| x else return;
    const source = std.mem.trim(u8, d.input.read(cx).text(), " \t\r\n");
    if (source.len == 0) {
        d.setErr(v.gpa, "Choose a local theme file or extension folder.");
        return cx.notify();
    }
    var scratch = std.heap.ArenaAllocator.init(v.gpa);
    defer scratch.deinit();
    const name = sourceName(source);
    const family_id = std.fmt.allocPrint(scratch.allocator(), "custom-{s}", .{vscode.slug(scratch.allocator(), name) catch "theme"}) catch return;
    var diag: vscode.Diagnostic = .{};
    const io = (ensure(cx.app) orelse return).io;
    var comp = library.compile(v.gpa, io, source, family_id, name, &diag) catch |err| {
        d.setErr(v.gpa, if (err == error.OutOfMemory) "out of memory" else diag.message());
        return cx.notify();
    };
    d.clearCompilation(v.gpa);
    for (comp.value.family.variants) |variant| {
        const id = v.gpa.dupe(u8, variant.id) catch continue;
        d.selected.append(v.gpa, id) catch v.gpa.free(id);
    }
    d.compilation = comp;
    comp = undefined;
    d.setErr(v.gpa, null);
    cx.notify();
}

/// `finish_import`.
pub fn finishImport(v: *SettingsView, cx: *Context(SettingsView)) void {
    const d = if (v.import) |*x| x else return;
    if (d.selected.items.len == 0) {
        d.setErr(v.gpa, "Select at least one variant to import.");
        return cx.notify();
    }
    const owned = if (d.compilation) |*c| c else return;
    const comp = &owned.value;
    var diag: vscode.Diagnostic = .{};
    const ids: []const []const u8 = @ptrCast(d.selected.items);
    if (install(cx.app, comp, ids, d.mode, &diag)) |_| {
        closeImport(v, cx);
    } else {
        d.setErr(v.gpa, diag.message());
        cx.notify();
    }
}

fn onBrowsed(app: *App, ctx: ?*anyopaque, path: ?[]const u8) void {
    const p = path orelse return;
    const id: zpui.EntityId = @enumFromInt(@intFromPtr(ctx));
    const weak: zpui.WeakEntity(SettingsView) = .{ .id = id };
    const Apply = struct {
        fn f(v: *SettingsView, chosen: []const u8, cx: *Context(SettingsView)) void {
            const d = v.import orelse return;
            d.input.update(cx, input.TextInput.setText, .{chosen});
            compileImport(v, cx);
        }
    };
    _ = weak.update(app, Apply.f, .{p});
}

/// "Browse…" (`choose_import_source`).
pub fn browse(_: *SettingsView, cx: *Context(SettingsView)) void {
    prompts.prompt(cx.app, .theme_import, @ptrFromInt(@intFromEnum(cx.entityId())), onBrowsed);
}

// ---- listeners ------------------------------------------------------------------------

fn onAdd(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    openImport(v, cx);
}

fn onBrowse(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    browse(v, cx);
}

fn onClose(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    closeImport(v, cx);
}

fn onCloseOutside(v: *SettingsView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    closeImport(v, cx);
}

fn onAction(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    submit(v, cx);
}

fn onMode(v: *SettingsView, mode: library.InstallMode, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    if (v.import) |*d| d.mode = mode;
    cx.notify();
}

fn variantAt(v: *SettingsView, ix: usize) ?*const zt.ThemeVariant {
    const d = v.import orelse return null;
    const c = d.compilation orelse return null;
    if (ix >= c.value.family.variants.len) return null;
    return &c.value.family.variants[ix];
}

fn onToggleVariant(v: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const variant = variantAt(v, ix) orelse return;
    const d = &v.import.?;
    if (d.isSelected(variant.id)) |i| {
        v.gpa.free(d.selected.orderedRemove(i));
    } else {
        const id = v.gpa.dupe(u8, variant.id) catch return;
        d.selected.append(v.gpa, id) catch v.gpa.free(id);
    }
    cx.notify();
}

fn onReviewVariant(v: *SettingsView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const variant = variantAt(v, ix) orelse return;
    const d = &v.import.?;
    const same = if (d.review_variant) |r| std.mem.eql(u8, r, variant.id) else false;
    if (d.review_variant) |r| v.gpa.free(r);
    d.review_variant = if (same) null else v.gpa.dupe(u8, variant.id) catch null;
    cx.notify();
}

const RowOp = struct { op: Op, ix: u16 };

fn onRowOp(v: *SettingsView, r: RowOp, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const list = entries(cx.app);
    if (r.ix >= list.len) return;
    const id = v.gpa.dupe(u8, list[r.ix].id) catch return;
    defer v.gpa.free(id);
    rowOp(v, r.op, id, cx);
}

/// A library row action by entry id (Review opens the mapping dialog).
pub fn rowOp(v: *SettingsView, op: Op, id: []const u8, cx: *Context(SettingsView)) void {
    var diag: vscode.Diagnostic = .{};
    if (v.library_error) |e| v.gpa.free(e);
    v.library_error = null;
    // Rust ignores reload results here (the row's status shows the warning).
    if (!run(cx.app, op, id, &diag) and op != .reload) v.library_error = v.gpa.dupe(u8, diag.message()) catch null;
    cx.notify();
}

fn onReview(v: *SettingsView, ix: u16, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const list = entries(cx.app);
    if (ix >= list.len) return;
    if (v.review_entry) |r| v.gpa.free(r);
    v.review_entry = v.gpa.dupe(u8, list[ix].id) catch null;
    cx.notify();
}

fn onReviewDone(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    closeReview(v, cx);
}

fn onReviewOutside(v: *SettingsView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    closeReview(v, cx);
}

pub fn closeReview(v: *SettingsView, cx: *Context(SettingsView)) void {
    if (v.review_entry) |r| v.gpa.free(r);
    v.review_entry = null;
    cx.notify();
}

/// Escape reaching Settings closes the import dialog, else the review (`dismiss_on_escape`).
pub fn dismissOnEscape(v: *SettingsView, cx: *Context(SettingsView)) bool {
    if (v.import != null) {
        closeImport(v, cx);
        return true;
    }
    if (v.review_entry != null) {
        closeReview(v, cx);
        return true;
    }
    return false;
}

// ---- rendering -------------------------------------------------------------------------

fn compactAction(t: *const Theme, label: []const u8, id: anytype) zpui.StatefulDiv {
    return w.textAction(t, .outlined, label).id(id);
}

fn paletteOf(t: *const Theme) zpui.Div {
    return div().flexNone().w(px(30)).h(px(18)).rounded(px(5)).overflowHidden().border1().borderColor(t.border).flex()
        .child(div().w1_3().hFull().bg(t.surface))
        .child(div().w1_3().hFull().bg(t.bg))
        .child(div().w1_3().hFull().bg(t.accent));
}

fn sampleTheme(variant: *const zt.ThemeVariant) *Theme {
    const t = zpui.window.arena_mod.current().create(Theme, zt.Theme.fromVariant(variant, .theme_default, .theme_default));
    return @constCast(t);
}

/// `import_scene_preview`: a miniature shell, code + ANSI swatches, diff chips.
fn scenePreview(variant: *const zt.ThemeVariant) zpui.Div {
    const t = sampleTheme(variant);
    var ansi = div().mtAuto().h(px(12)).flex().rounded(px(3)).overflowHidden();
    for (t.terminal.ansi[0..8]) |c| ansi = ansi.child(div().flex1().hFull().bg(c));
    return div().wFull().h(px(86)).flex().gap(px(8))
        .child(div().w(px(152)).hFull().overflowHidden().rounded(px(8)).border1().borderColor(t.border)
        .child(@import("appearance.zig").miniature(t, .all)))
        .child(div().flex1().minW0().hFull().rounded(px(8)).border1().borderColor(t.border).bg(t.bg).p(px(9))
        .flex().flexCol().gap(px(6))
        .child(div().textSize(rems(10)).fontFamily(t.font_mono).flex().flexRow()
        .child(div().textColor(t.syntax.color(.keyword)).child("fn "))
        .child(div().textColor(t.syntax.color(.function)).child("preview"))
        .child(div().textColor(t.syntax.color(.punctuation)).child("() {")))
        .child(div().textSize(rems(10)).fontFamily(t.font_mono).textColor(t.syntax.color(.string)).child("  \"Theme mapping\""))
        .child(ansi))
        .child(div().w(px(84)).hFull().rounded(px(8)).border1().borderColor(t.border).bg(t.surface).p(px(8))
        .flex().flexCol().gap(px(6))
        .child(div().h(px(12)).rounded(px(3)).bg(t.diff_add.opacity(0.35)))
        .child(div().h(px(12)).rounded(px(3)).bg(t.diff_del.opacity(0.35)))
        .child(div().h(px(12)).rounded(px(3)).bg(t.accent_wash)));
}

fn reportPanel(t: *const Theme, r: *const vscode.ImportReport) zpui.StatefulDiv {
    var p = div().id(zpui.fmt("theme-report-{s}", .{r.sourceHash})).mt(px(8)).wFull().maxH(px(168)).overflowYScroll().rounded(px(8)).border1().borderColor(t.border)
        .bg(t.surface_raised.opacity(0.35)).p(px(10)).textSize(rems(11)).lineHeight(px(16)).textColor(t.text_muted)
        .child(div().textColor(t.text).child(zpui.fmt("{d} mapped · {d} adjusted · {d} inferred/fallback · {d} unsupported · {d} warnings · {d} validation", .{
        r.mappings.len, r.adjustments.len, r.fallbacks.len, r.dropped.len, r.warnings.len, r.validation.len,
    })));
    for (r.adjustments) |x| p = p.child(div().mt(px(4)).child(zpui.fmt("Adjusted · {s} {s} → {s} · {s}", .{ x.zeronRole, x.original, x.resolved, x.reason })));
    for (r.fallbacks) |x| p = p.child(div().mt(px(4)).child(zpui.fmt("Fallback · {s}", .{x})));
    for (r.warnings) |x| p = p.child(div().mt(px(4)).child(zpui.fmt("Warning · {s}", .{x})));
    for (r.validation) |x| p = p.child(div().mt(px(4)).child(zpui.fmt("Validation {s} {s} · {s}", .{ if (x.category == .structural) "Structural" else "Contrast", if (x.severity == .warning) "Warning" else "Error", x.message })));
    for (r.dropped) |x| p = p.child(div().mt(px(4)).child(zpui.fmt("Unsupported · {s}", .{x})));
    for (r.mappings) |x| p = p.child(div().mt(px(4)).child(zpui.fmt("{s} ← {s}", .{ x.zeronRole, x.vscodeKey })));
    return p;
}

fn modeControl(v: *SettingsView, t: *const Theme, label: []const u8, description: []const u8, value: library.InstallMode, cx: *Context(SettingsView)) zpui.StatefulDiv {
    const active = v.import.?.mode == value;
    var dot = div().size(px(16)).roundedFull().border1().borderColor(if (active) t.accent else t.border_strong).flex().itemsCenter().justifyCenter();
    if (active) dot = dot.child(div().size(px(8)).roundedFull().bg(t.accent));
    var c = div().id(.{ "theme-import-mode", @intFromEnum(value) }).flex1().minW0().p(px(10)).rounded(px(9)).border1()
        .borderColor(if (active) t.accent else t.border).bg(if (active) t.accent_wash else t.surface_raised.opacity(0.28))
        .cursorPointer().onClick(cx.listenerWith(value, onMode))
        .child(div().flex().itemsCenter().gap(px(7)).child(dot)
        .child(div().textSize(rems(12)).fontWeight(500).textColor(if (active) t.text else t.text_muted).child(label)))
        .child(div().mt(px(4)).ml(px(23)).textSize(rems(10.5)).textColor(t.text_muted).child(description));
    if (!active) c = c.hover(sb.bg(t.surface_raised_hover));
    return c;
}

fn sectionLabel(t: *const Theme, label: []const u8) zpui.Div {
    return div().mb(px(7)).textSize(rems(11)).fontWeight(600).textColor(t.text_muted).child(label);
}

fn modal(id: []const u8, window: *Window, card: anytype) zpui.AnyElement {
    const vp = window.viewportSize();
    return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 }).child(
        div().id(id).occlude().w(px(vp.width)).h(px(vp.height)).bg(zpui.color.black.alpha(0.35))
            .flex().itemsCenter().justifyCenter()
            .child(ui.anim.menuIn(id, div().child(ui.effects.frosted(16, zt.layout.menu_blur, card)), 2)),
    )).withPriority(3));
}

/// The "Add a theme" dialog (`render_import_dialog`).
pub fn importDialog(v: *SettingsView, window: *Window, cx: *Context(SettingsView)) ?zpui.AnyElement {
    const d = if (v.import) |*x| x else return null;
    if (d.focus_pending) {
        d.focus_pending = false;
        window.focus(d.input.read(cx).focusHandle());
    }
    const t_val = ui.theme.get(cx).forPopup();
    const t = &t_val;
    const hairline = t.hairline(0.08);
    const comp: ?*const vscode.SourceCompilation = if (d.compilation) |*c| &c.value else null;
    const ready = comp != null and d.selected.items.len > 0;

    var main = div().id("theme-import-main").maxH(px(520)).overflowYScroll().px(px(20)).pb(px(18)).flex().flexCol()
        .child(sectionLabel(t, "Source"))
        .child(div().flex().itemsCenter().gap(px(8))
        .child(div().flex1().minW0().h(px(36)).px(px(12)).rounded(px(8)).border1().borderColor(t.hairline(0.08)).bg(t.ink(0.04))
        .flex().itemsCenter().textSize(rems(13)).child(d.input))
        .child(compactAction(t, "Browse…", "theme-import-browse").h(px(36)).px(px(12)).flexNone().onClick(cx.listener(onBrowse))))
        .child(div().mt(px(16)).child(sectionLabel(t, "Keep it up to date"))
        .child(div().flex().gap(px(8))
        .child(modeControl(v, t, "Import a copy", "Works independently from the original file.", .snapshot, cx))
        .child(modeControl(v, t, "Link to source", "Reload changes from the file on disk.", .link, cx))));

    if (comp) |c| {
        const nv = c.family.variants.len;
        main = main.child(div().mt(px(18)).pt(px(16)).borderT1().borderColor(hairline).flex().itemsBaseline().justifyBetween()
            .child(sectionLabel(t, "Detected themes").mb(px(0)))
            .child(div().textSize(rems(10.5)).textColor(t.text_muted).child(zpui.fmt("{d} variant{s}", .{ nv, if (nv == 1) "" else "s" }))));
        for (c.family.variants, 0..) |*variant, ix| {
            const selected_now = d.isSelected(variant.id) != null;
            const review_open = if (d.review_variant) |r| std.mem.eql(u8, r, variant.id) else false;
            const sample = sampleTheme(variant);
            var check = div().id(.{ "theme-import-select", ix }).size(px(18)).rounded(px(5)).border1()
                .borderColor(if (selected_now) t.accent else t.border_strong).bg(if (selected_now) t.accent else t.bg)
                .flex().itemsCenter().justifyCenter().cursorPointer().onClick(cx.listenerWith(ix, onToggleVariant));
            if (selected_now) check = check.child(ui.icon.of(.check, 12, t.on_accent));
            var row = div().id(.{ "theme-import-row", ix }).mt(px(8)).p(px(11)).rounded(px(10)).border1()
                .borderColor(if (selected_now) t.accent.opacity(0.7) else t.border)
                .bg(if (selected_now) t.accent_wash.opacity(0.42) else t.surface_raised.opacity(0.22))
                .flex().flexCol()
                .child(div().flex().itemsCenter().gap(px(9))
                .child(check)
                .child(paletteOf(sample))
                .child(div().flex1().minW0()
                .child(div().textSize(rems(12.5)).fontWeight(500).textColor(t.text).child(variant.name))
                .child(div().textSize(rems(11)).textColor(t.text_muted).child(if (variant.appearance.isDark()) "Dark" else "Light")))
                .child(compactAction(t, if (review_open) "Hide details" else "Details", .{ "theme-import-review", ix }).onClick(cx.listenerWith(ix, onReviewVariant))));
            if (review_open) {
                row = row.child(div().mt(px(10)).pt(px(10)).borderT1().borderColor(hairline).child(scenePreview(variant)));
                if (c.report(variant.id)) |r| row = row.child(reportPanel(t, r));
            }
            main = main.child(row);
        }
        for (c.failures) |f| main = main.child(div().mt(px(8)).p(px(10)).rounded(px(8)).bg(t.warning.opacity(0.08))
            .textSize(rems(11)).textColor(t.warning).child(zpui.fmt("{s} could not be compiled · {s}", .{ f.name, f.message })));
    } else {
        main = main.child(div().mt(px(14)).flex().itemsStart().gap(px(7)).textSize(rems(11)).lineHeight(px(16)).textColor(t.text_muted)
            .child(div().mt(px(1)).flexNone().child(ui.icon.of(.info_circle, 13, t.text_muted)))
            .child("Zeron finds light and dark variants automatically."));
    }
    if (d.err) |e| main = main.child(div().mt(px(12)).p(px(10)).rounded(px(8)).bg(t.danger.opacity(0.08)).flex().itemsStart().gap(px(7))
        .textSize(rems(11)).lineHeight(px(16)).textColor(t.danger)
        .child(div().flexNone().mt(px(1)).child(ui.icon.of(.danger_triangle, 13, t.danger)))
        .child(div().flex1().minW0().truncate().child(e)));

    const header = div().px(px(20)).pt(px(18)).pb(px(16)).flex().itemsStart().gap(px(16))
        .child(div().flex1().minW0()
        .child(dialog.title(t, "Add a theme"))
        .child(dialog.body(t, "Import a local theme into your library or keep it linked to its source.").mt(px(4))))
        .child(div().id("theme-import-close").size(px(28)).rounded(px(7)).border1().borderColor(t.border)
        .bg(t.surface_raised.opacity(0.28)).flex().itemsCenter().justifyCenter().cursorPointer()
        .hover(sb.bg(t.surface_raised_hover)).onClick(cx.listener(onClose))
        .child(ui.icon.of(.close, 12, t.text_muted)));
    var action = w.textAction(t, .solid, if (comp != null) "Import selected" else "Analyze theme").id("theme-import-action")
        .h(px(34)).px(px(14)).py(px(0)).flex().itemsCenter();
    action = if (comp != null and !ready) action.opacity(0.45) else action.onClick(cx.listener(onAction));
    const footer = div().borderT1().borderColor(hairline).bg(t.surface_raised.opacity(0.18)).px(px(20)).py(px(12))
        .flex().itemsCenter().justifyEnd().gap(px(8))
        .child(compactAction(t, "Cancel", "theme-import-cancel").h(px(34)).px(px(13)).onClick(cx.listener(onClose)))
        .child(action);
    const card = dialog.card(t).id("theme-import-card").w(px(600)).maxH(px(760)).p(px(0)).overflowHidden()
        .onMouseDownOut(cx.listener(onCloseOutside))
        .child(header).child(main).child(footer);
    return modal("theme-import-dialog", window, card);
}

/// "Theme mapping" (`render_review_dialog`).
pub fn reviewDialog(v: *SettingsView, window: *Window, cx: *Context(SettingsView)) ?zpui.AnyElement {
    const id = v.review_entry orelse return null;
    const s = cx.app.tryGlobal(State) orelse return null;
    const e = s.lib.entry(id) orelse return null;
    const t_val = ui.theme.get(cx).forPopup();
    const t = &t_val;
    var card = dialog.card(t).id("theme-review-card").w(px(660)).maxH(px(720)).overflowYScroll()
        .onMouseDownOut(cx.listener(onReviewOutside))
        .child(dialog.title(t, "Theme mapping"))
        .child(dialog.body(t, zpui.fmt("{s} · {s}", .{ e.name, e.source.label() })).mt(px(6)));
    for (e.family.variants) |*variant| {
        card = card.child(div().mt(px(14)).textSize(rems(12.5)).fontWeight(500).child(variant.name)).child(scenePreview(variant));
        if (e.report(variant.id)) |r| card = card.child(reportPanel(t, r));
    }
    card = card.child(div().mt(px(16)).flex().justifyEnd()
        .child(w.textAction(t, .solid, "Done").id("theme-review-close").onClick(cx.listener(onReviewDone))));
    return modal("theme-review-dialog", window, card);
}

fn entryRow(v: *SettingsView, t: *const Theme, e: *const library.Entry, ix: usize, cx: *Context(SettingsView)) zpui.Div {
    _ = v;
    const linked = e.source.isLinked();
    const src = e.source.path() orelse "Self-contained snapshot";
    const nv = e.family.variants.len;
    const status = switch (e.status) {
        .ready => zpui.fmt("{s} · {d} variant{s} · {s}", .{ e.source.label(), nv, if (nv == 1) "" else "s", src }),
        .warning => |m| zpui.fmt("Using last known good · {s}", .{m}),
    };
    const i: u16 = @intCast(ix);
    var actions = div().flexNone().flex().itemsCenter().gap(px(2));
    if (linked) actions = actions.child(compactAction(t, "Reload", .{ "theme-reload", ix }).onClick(cx.listenerWith(RowOp{ .op = .reload, .ix = i }, onRowOp)));
    actions = actions
        .child(compactAction(t, "Reveal", .{ "theme-reveal", ix }).onClick(cx.listenerWith(RowOp{ .op = .reveal, .ix = i }, onRowOp)))
        .child(compactAction(t, "Review", .{ "theme-review", ix }).onClick(cx.listenerWith(i, onReview)))
        .child(compactAction(t, "Duplicate as editable", .{ "theme-duplicate", ix }).onClick(cx.listenerWith(RowOp{ .op = .duplicate, .ix = i }, onRowOp)));
    if (linked) actions = actions.child(compactAction(t, "Unlink", .{ "theme-unlink", ix }).onClick(cx.listenerWith(RowOp{ .op = .unlink, .ix = i }, onRowOp)));
    actions = actions.child(compactAction(t, "Remove", .{ "theme-remove", ix }).textColor(t.danger).onClick(cx.listenerWith(RowOp{ .op = .remove, .ix = i }, onRowOp)));
    return w.cardRow(t, false)
        .child(div().flex1().minW(px(160)).child(w.rowTitle(t, e.name))
        .child(div().truncate().textSize(rems(11)).textColor(if (e.status == .warning) t.warning else t.text_muted).child(status)))
        .child(actions);
}

fn groupLabel(t: *const Theme, label: []const u8) zpui.Div {
    return div().mx(px(16)).pt(px(12)).pb(px(4)).borderT1().borderColor(w.rowDivider(t)).textSize(rems(12)).textColor(t.text_muted).child(label);
}

/// The library card (`render_theme_library_rows`): "Add theme", then Imported and Linked groups.
pub fn libraryCard(v: *SettingsView, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    var c = w.sectionCard(t).mt(px(32))
        .child(w.cardRow(t, true).child(div().flex1().minW(px(160)).child(w.rowTitle(t, "Theme library")))
        .child(w.textAction(t, .solid, "Add theme").id("theme-library-add").onClick(cx.listener(onAdd))));
    const list = entries(cx.app);
    var any_imported = false;
    var any_linked = false;
    for (list) |e| {
        if (e.source.isLinked()) any_linked = true else any_imported = true;
    }
    if (any_imported) {
        c = c.child(groupLabel(t, "Imported"));
        for (list, 0..) |*e, ix| if (!e.source.isLinked()) {
            c = c.child(entryRow(v, t, e, ix, cx));
        };
    }
    if (any_linked) {
        c = c.child(groupLabel(t, "Linked"));
        for (list, 0..) |*e, ix| if (e.source.isLinked()) {
            c = c.child(entryRow(v, t, e, ix, cx));
        };
    }
    if (v.library_error orelse loadWarning(cx.app)) |msg| c = c.child(div().mx(px(16)).py(px(10)).borderT1().borderColor(w.rowDivider(t)).child(w.errorStrip(t, msg).mt0()));
    return c;
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "source names follow the file stem or the package folder" {
    try testing.expectEqualStrings("night-owl", sourceName("/x/night-owl.json"));
    try testing.expectEqualStrings("dracula", sourceName("/ext/dracula/package.json"));
    try testing.expectEqualStrings("dracula", sourceName("/ext/dracula"));
}
