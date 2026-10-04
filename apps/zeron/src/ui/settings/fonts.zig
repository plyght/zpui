//! Installed-font pickers (zeron `typography.rs` `FontAvailability`,
//! `register_fonts`, `resolve_effective*`, and `appearance.rs`
//! `render_font_picker`): the interface and code/diff slots pick from every
//! family with Latin metrics, the terminal only from measured fixed-width
//! ones. Each slot is a searchable dropdown (prefix matches rank first),
//! with ↑/↓/Home/End/Enter/Escape. A family the device no longer has falls
//! back at render time (Geist; Geist Mono for code/terminal) without
//! touching the saved choice.
//!
//! ```zig
//! fonts.ensureLoaded(app);                       // background scan, once
//! fonts.effective(.terminal, requested)          // what renders
//! row.child(fonts.picker(view, .ui, theme, cx))  // trigger (+ open menu)
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const App = zpui.App;
const Context = zpui.Context;
const Window = zpui.Window;
const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const UiFontFamily = zt.typography.UiFontFamily;
const Family = zpui.text.font_catalog.Family;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;

pub const FontKind = enum(u8) {
    ui,
    terminal,
    code,

    pub const all = [_]FontKind{ .ui, .terminal, .code };

    pub fn slug(self: FontKind) []const u8 {
        return switch (self) {
            .ui => "interface",
            .terminal => "terminal",
            .code => "code",
        };
    }

    pub fn label(self: FontKind) []const u8 {
        return switch (self) {
            .ui => "Interface font",
            .terminal => "Terminal font",
            .code => "Code & diff font",
        };
    }

    pub fn requested(self: FontKind, s: *const model.UiSettings) UiFontFamily {
        return switch (self) {
            .ui => s.theme.ui_font_family,
            .terminal => s.theme.terminal_font_family,
            .code => s.theme.code_font_family,
        };
    }
};

// ---- availability -------------------------------------------------------------------

/// The scanned catalog. Process-wide (the theme builder has no App); set on
/// the main thread when the background scan lands.
pub const Catalog = struct {
    families: []Family,
};

pub var catalog: ?Catalog = null;
var loading = std.atomic.Value(bool).init(false);

fn sameFamily(a: UiFontFamily, b: UiFontFamily) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .installed => |n| std.mem.eql(u8, n, b.installed),
        else => true,
    };
}

fn installedEntry(name: []const u8) ?Family {
    const c = catalog orelse return null;
    for (c.families) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// `FontAvailability::is_available` (+ `is_fixed_width_available` for the terminal).
/// Before the scan lands every request counts as available.
pub fn isAvailable(kind: FontKind, family: UiFontFamily) bool {
    const fixed_only = kind == .terminal;
    return switch (family) {
        .geist => !fixed_only,
        .geist_mono => true,
        .system => !fixed_only,
        .installed => |name| if (catalog == null) true else if (installedEntry(name)) |f| (!fixed_only or f.fixed_width) else false,
    };
}

/// `resolve_effective` / `resolve_effective_mono`.
pub fn effective(kind: FontKind, requested: UiFontFamily) UiFontFamily {
    if (isAvailable(kind, requested)) return requested;
    return if (kind == .ui) .geist else .geist_mono;
}

/// The slot's catalog: bundled first, then installed families by name.
pub fn choices(a: std.mem.Allocator, kind: FontKind) []const UiFontFamily {
    var list: std.ArrayList(UiFontFamily) = .empty;
    if (kind == .terminal) {
        list.append(a, .geist_mono) catch {};
    } else {
        list.appendSlice(a, &.{ .geist, .geist_mono, .system }) catch {};
    }
    if (catalog) |c| for (c.families) |f| {
        if (std.mem.eql(u8, f.name, "Geist") or std.mem.eql(u8, f.name, "Geist Mono")) continue;
        if (kind == .terminal and !f.fixed_width) continue;
        list.append(a, .{ .installed = f.name }) catch {};
    };
    return list.items;
}

/// `filter_families`: prefix matches, then substring; catalog order within.
pub fn filter(a: std.mem.Allocator, query: []const u8, list: []const UiFontFamily) []const UiFontFamily {
    if (std.mem.trim(u8, query, " \t").len == 0) return list;
    var out: std.ArrayList(UiFontFamily) = .empty;
    for (0..2) |pass| for (list) |f| {
        const r = matchRank(query, f.label()) orelse continue;
        if (r == pass) out.append(a, f) catch {};
    };
    return out.items;
}

fn matchRank(query: []const u8, label_: []const u8) ?u1 {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return 1;
    if (q.len <= label_.len and std.ascii.eqlIgnoreCase(label_[0..q.len], q)) return 0;
    if (std.ascii.findIgnoreCase(label_, q) != null) return 1;
    return null;
}

const ScanJob = struct {
    app: *App,
    gpa: std.mem.Allocator,

    pub fn run(self: *ScanJob) ?[]Family {
        return zpui.text.font_catalog.installedFamilies(self.gpa) catch null;
    }

    pub fn finish(self: *ScanJob, result: ?[]Family) void {
        loading.store(false, .release);
        const fams = result orelse return;
        if (catalog) |old| zpui.text.font_catalog.freeFamilies(std.heap.page_allocator, old.families);
        catalog = .{ .families = fams };
        // A requested family that vanished now resolves to its fallback.
        store.applyTheme(self.app);
    }
};

/// Scan the installed families once (background), then re-theme.
pub fn ensureLoaded(app: *App) void {
    if (catalog != null or loading.swap(true, .acq_rel)) return;
    // The catalog outlives any one App (tests open many), so it lives in page memory.
    var task = app.backgroundExecutor().spawn(ScanJob{ .app = app, .gpa = std.heap.page_allocator }) catch {
        loading.store(false, .release);
        return;
    };
    task.detach();
}

// ---- picker state (lives on SettingsView) ----------------------------------------------

pub const Picker = struct {
    open: ?FontKind = null,
    /// Keyboard highlight (borrowed from the catalog / static).
    highlight: UiFontFamily = .geist,
    search: ?zpui.Entity(input.TextInput) = null,
    sub: ?zpui.Subscription = null,
    scroll: ?zpui.ScrollHandle = null,
    /// A click outside closed this kind's menu just now (the trigger's own
    /// click must not reopen it).
    dismissed: ?struct { kind: FontKind, at: u64 } = null,

    pub fn deinit(self: *Picker, app: *App) void {
        if (self.sub) |*s| s.deinit();
        if (self.search) |s| s.release(app);
        if (self.scroll) |s| s.release();
    }
};

fn ensureSearch(v: *SettingsView, cx: *Context(SettingsView)) zpui.Entity(input.TextInput) {
    if (v.fonts.search) |s| return s;
    const theme = ui.theme.get(cx).forPopup();
    const s = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
        .placeholder = "Search fonts",
        .key_context = "PaletteSearch",
        .single_line = true,
        .edge_fade = false,
        .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
    }}) catch @panic("OOM");
    v.fonts.search = s;
    v.fonts.sub = cx.subscribe(s, onSearch) catch null;
    v.fonts.scroll = zpui.ScrollHandle.init(cx.gpa());
    return s;
}

fn searchText(v: *SettingsView, cx: anytype) []const u8 {
    const s = v.fonts.search orelse return "";
    return s.read(cx).text();
}

fn visible(v: *SettingsView, kind: FontKind, cx: anytype) []const UiFontFamily {
    const a = zpui.window.arena_mod.frameAllocator();
    return filter(a, searchText(v, cx), choices(a, kind));
}

fn indexOf(list: []const UiFontFamily, f: UiFontFamily) ?usize {
    for (list, 0..) |x, i| if (sameFamily(x, f)) return i;
    return null;
}

fn onSearch(v: *SettingsView, _: zpui.Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(SettingsView)) void {
    var sc = view_mod.scratch(v.gpa);
    sc.begin();
    defer sc.end();
    switch (ev.*) {
        .edited => {
            const kind = v.fonts.open orelse return;
            // Keep the highlight inside the filtered list (`clamp_highlight`).
            const list = visible(v, kind, cx);
            if (indexOf(list, v.fonts.highlight) == null) v.fonts.highlight = firstAvailable(list, kind);
            if (v.fonts.scroll) |s| s.setOffset(.{ .x = 0, .y = 0 });
            cx.notify();
        },
        else => {},
    }
}

fn firstAvailable(list: []const UiFontFamily, kind: FontKind) UiFontFamily {
    for (list) |f| if (isAvailable(kind, f)) return f;
    return if (kind == .terminal) .geist_mono else .system;
}

fn lastAvailable(list: []const UiFontFamily, kind: FontKind) UiFontFamily {
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (isAvailable(kind, list[i])) return list[i];
    }
    return if (kind == .terminal) .geist_mono else .system;
}

fn step(list: []const UiFontFamily, current: UiFontFamily, delta: isize, kind: FontKind) UiFontFamily {
    if (list.len == 0) return current;
    const at: isize = @intCast(indexOf(list, current) orelse 0);
    var ix = at + delta;
    while (ix >= 0 and ix < list.len) : (ix += delta) {
        if (isAvailable(kind, list[@intCast(ix)])) return list[@intCast(ix)];
    }
    return list[@intCast(at)];
}

pub fn toggle(v: *SettingsView, kind: FontKind, window: *Window, cx: *Context(SettingsView)) void {
    ensureLoaded(cx.app);
    v.closeSelect();
    if (v.fonts.dismissed) |d| if (d.kind == kind and SettingsView.now(cx) -| d.at < 400 * std.time.ns_per_ms) {
        v.fonts.dismissed = null;
        return;
    };
    if (v.fonts.open == kind) return close(v, cx);
    const s = ensureSearch(v, cx);
    s.update(cx, input.TextInput.setText, .{""});
    v.fonts.open = kind;
    v.fonts.highlight = effective(kind, kind.requested(store.current(cx)));
    if (v.fonts.scroll) |sc| sc.setOffset(.{ .x = 0, .y = 0 });
    window.focus(s.read(cx).focusHandle());
    cx.notify();
}

pub fn close(v: *SettingsView, cx: *Context(SettingsView)) void {
    v.fonts.open = null;
    cx.notify();
}

/// `commit_font`: only an available family is applied.
pub fn commit(v: *SettingsView, kind: FontKind, family: UiFontFamily, cx: *Context(SettingsView)) void {
    if (!isAvailable(kind, family)) return;
    const Ctx = struct { kind: FontKind, family: UiFontFamily };
    const Set = struct {
        fn f(c: Ctx, s: *model.UiSettings, a: std.mem.Allocator) void {
            const fam: UiFontFamily = switch (c.family) {
                .installed => |n| .{ .installed = a.dupe(u8, n) catch return },
                else => c.family,
            };
            switch (c.kind) {
                .ui => s.theme.ui_font_family = fam,
                .terminal => s.theme.terminal_font_family = fam,
                .code => s.theme.code_font_family = fam,
            }
        }
    };
    store.update(cx, .debounced, Ctx{ .kind = kind, .family = family }, Set.f);
    store.applyTheme(cx.app);
    close(v, cx);
}

/// Keys while a font menu is open (called from the view's capture handler).
/// Returns whether the key was consumed.
pub fn onKey(v: *SettingsView, ks: zpui.input.Keystroke, window: *Window, cx: *Context(SettingsView)) bool {
    const kind = v.fonts.open orelse return false;
    const list = visible(v, kind, cx);
    const key = ks.key;
    const eq = std.mem.eql;
    const ctrl = ks.modifiers.control;
    if (eq(u8, key, "up") or (ctrl and eq(u8, key, "p"))) {
        v.fonts.highlight = step(list, v.fonts.highlight, -1, kind);
    } else if (eq(u8, key, "down") or (ctrl and eq(u8, key, "n"))) {
        v.fonts.highlight = step(list, v.fonts.highlight, 1, kind);
    } else if (eq(u8, key, "home")) {
        v.fonts.highlight = firstAvailable(list, kind);
    } else if (eq(u8, key, "end")) {
        v.fonts.highlight = lastAvailable(list, kind);
    } else if (eq(u8, key, "enter")) {
        commit(v, kind, v.fonts.highlight, cx);
        window.focus(v.focus);
        return true;
    } else if (eq(u8, key, "escape")) {
        close(v, cx);
        window.focus(v.focus);
        return true;
    } else return false;
    if (indexOf(list, v.fonts.highlight)) |i| if (v.fonts.scroll) |s| s.scrollToItem(i);
    cx.notify();
    return true;
}

// ---- rendering --------------------------------------------------------------------------

const Pick = struct { kind: FontKind, ix: u32 };

fn onTrigger(v: *SettingsView, kind: FontKind, _: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
    toggle(v, kind, window, cx);
}

fn onOption(v: *SettingsView, pick: Pick, _: *const zpui.ClickEvent, window: *Window, cx: *Context(SettingsView)) void {
    var sc = view_mod.scratch(v.gpa);
    sc.begin();
    defer sc.end();
    const list = visible(v, pick.kind, cx);
    if (pick.ix >= list.len) return;
    commit(v, pick.kind, list[pick.ix], cx);
    window.focus(v.focus);
}

fn onOutside(v: *SettingsView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    const kind = v.fonts.open orelse return;
    v.fonts.dismissed = .{ .kind = kind, .at = SettingsView.now(cx) };
    close(v, cx);
}

/// The family trigger (220px) and, while open, its searchable menu.
pub fn picker(v: *SettingsView, kind: FontKind, t: *const Theme, cx: *Context(SettingsView)) zpui.StatefulDiv {
    ensureLoaded(cx.app);
    const open = v.fonts.open == kind;
    const eff = effective(kind, kind.requested(store.current(cx)));
    const key = zpui.fmt("settings-font-{s}", .{kind.slug()});
    const fill = if (open) w.selectFill(t, true) else ui.hover.blend(cx, key, w.selectFill(t, false), w.selectFill(t, true));
    var trigger = w.selectTrigger(t, fill).id(.{ "font-dropdown", @intFromEnum(kind) }).w(px(220))
        .fontFamily(t.font_sans_fixed)
        .onHover(cx.listenerWith(kind, onHover))
        .onClick(cx.listenerWith(kind, onTrigger))
        .child(div().flex1().minW0().truncate().child(eff.label()))
        .child(w.selectChevron(t, open));
    if (open) trigger = trigger.child(menu(v, kind, t, cx));
    return trigger;
}

fn onHover(_: *SettingsView, kind: FontKind, hovered: *const bool, _: *Window, cx: *Context(SettingsView)) void {
    ui.hover.set(cx, zpui.fmt("settings-font-{s}", .{kind.slug()}), hovered.*);
}

fn menu(v: *SettingsView, kind: FontKind, t_page: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    const t_val = t_page.forPopup();
    const t = &t_val;
    const list = visible(v, kind, cx);
    const eff = effective(kind, kind.requested(store.current(cx)));
    var rows = div().id(.{ "font-scroll", @intFromEnum(kind) }).maxH(px(260)).overflowYScroll()
        .flex().flexCol().gap(px(2));
    if (v.fonts.scroll) |s| rows = rows.trackScroll(s);
    for (list, 0..) |f, ix| {
        const available = isAvailable(kind, f);
        const active = sameFamily(f, eff);
        const focused = sameFamily(f, v.fonts.highlight);
        var row = ui.popover.menuRow(t, active or focused).id(.{ "font-option", @as(usize, @intFromEnum(kind)) * 100_000 + ix });
        if (available) row = row.onClick(cx.listenerWith(Pick{ .kind = kind, .ix = @intCast(ix) }, onOption)) else row = row.opacity(0.45);
        rows = rows.child(row.child(div().flex1().minW0().truncate().child(f.label())).child(w.selectCheck(t, active)));
    }
    const body: zpui.AnyElement = if (list.len == 0)
        zpui.intoAnyElement(div().px(px(8)).py(px(6)).textSize(px(12)).textColor(t.text_faint)
            .child(if (searchText(v, cx).len > 0) "No matching fonts" else "No fonts"))
    else if (v.fonts.scroll) |s|
        zpui.intoAnyElement(ui.effects.edgeFaded(rows, .{ .band = 12, .top = true, .bottom = true, .scroll = s }))
    else
        zpui.intoAnyElement(rows);
    const search = v.fonts.search.?;
    const card = ui.popover.card(t).w(px(220)).fontFamily(t.font_sans_fixed)
        .onMouseDownOut(cx.listener(onOutside))
        .child(div().mb(px(4)).px(px(10)).py(px(6)).rounded(px(ui.popover.menu_item_radius)).bg(t.ink(0.04)).textSize(rems(13)).child(search))
        .child(body);
    return div().absolute().top(zpui.relative(1)).right(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.top_right).snapToWindowWithMargin(.all(8))
            .child(ui.anim.menuIn("settings-font-menu", div().occlude().pt(px(6)).child(ui.popover.frostedCard(card)), -2)),
    ).withPriority(1));
}

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "search ranks prefix matches before substring matches" {
    const list = [_]UiFontFamily{ .geist, .geist_mono, .system, .{ .installed = "Fira Mono" }, .{ .installed = "Monaco" } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = filter(arena.allocator(), "mon", &list);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("Monaco", out[0].label());
    try testing.expectEqualStrings("Geist Mono", out[1].label());
    try testing.expectEqualStrings("Fira Mono", out[2].label());
    try testing.expectEqual(list.len, filter(arena.allocator(), "  ", &list).len);
}

test "the terminal only offers measured fixed-width families; missing ones fall back" {
    const saved = catalog;
    defer catalog = saved;
    var fams = [_]Family{ .{ .name = "Arial", .fixed_width = false }, .{ .name = "Menlo", .fixed_width = true } };
    catalog = .{ .families = &fams };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const term = choices(arena.allocator(), .terminal);
    try testing.expectEqual(@as(usize, 2), term.len);
    try testing.expectEqualStrings("Menlo", term[1].installed);
    try testing.expectEqual(@as(usize, 5), choices(arena.allocator(), .ui).len);
    try testing.expect(isAvailable(.ui, .{ .installed = "Arial" }));
    try testing.expect(!isAvailable(.terminal, .{ .installed = "Arial" }));
    try testing.expect(effective(.terminal, .{ .installed = "Arial" }) == .geist_mono);
    try testing.expect(effective(.ui, .{ .installed = "Gone Sans" }) == .geist);
    try testing.expectEqualStrings("Menlo", effective(.code, .{ .installed = "Menlo" }).installed);
    // Stepping skips nothing available and stays put at the ends.
    const list = choices(arena.allocator(), .ui);
    try testing.expectEqualStrings("Arial", step(list, .system, 1, .ui).installed);
    try testing.expect(step(list, .geist, -1, .ui) == .geist);
}
