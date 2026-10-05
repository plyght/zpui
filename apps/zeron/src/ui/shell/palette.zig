//! Command palette (zeron `shell/command_palette.rs`): mod-k summons a
//! frosted 560px card (radius 16) over a 0.35 scrim — search row with the
//! magnifier and a `Ctrl+K` hint, Actions (New chat, New project, Open
//! settings, theme switch) with kbd hints, a hairline, then chat history rows
//! in the sidebar's detailed layout, and a footer of key hints.
//!
//! ```zig
//! self.palette = try cx.newWith(Palette, Palette.init, .{ app_state, window });
//! // events: Palette.Close, Palette.Activate{ .entry }
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const icon = ui.icon;
const view = model.view;
const builtin = @import("builtin");

const history_limit = 30;
const results_fade_band: f32 = 18;

pub const Entry = union(enum) {
    new_chat,
    new_project,
    settings,
    theme_light,
    theme_dark,
    chat: usize, // index into `chat_ids`
};

pub const Close = struct {};
pub const Activate = struct { entry: Entry, chat_id: ?[]const u8 = null };

fn mod() []const u8 {
    return if (builtin.os.tag == .macos) "⌘" else "Ctrl+";
}

pub const Palette = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    search: Entity(input.TextInput),
    focus: zpui.FocusHandle,
    scroll: zpui.ScrollHandle,
    active: usize = 0,
    chat_ids: std.ArrayList([]u8) = .empty,
    subs: zpui.Subscriptions = .{},

    pub const Events = .{ Close, Activate };

    pub fn init(state: Entity(model.AppState), window: *Window, cx: *Context(Palette)) !Palette {
        const theme = ui.theme.get(cx).forPopup();
        const search = try cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Search commands and chats…",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 14,
            .line_height = 20,
            .colors = .{ .text = theme.text, .placeholder = theme.text_muted, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }});
        var self: Palette = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .search = search,
            .focus = cx.focusHandle(),
            .scroll = zpui.ScrollHandle.init(cx.gpa()),
        };
        try self.subs.add(cx.gpa(), try cx.subscribe(search, onSearch));
        window.focus(search.read(cx).focusHandle());
        return self;
    }

    pub fn deinit(self: *Palette, app: *App) void {
        self.subs.deinit(self.gpa);
        for (self.chat_ids.items) |c| self.gpa.free(c);
        self.chat_ids.deinit(self.gpa);
        self.scroll.release();
        self.focus.release(app);
        self.search.release(app);
        self.state.release(app);
    }

    fn onSearch(self: *Palette, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(Palette)) void {
        switch (ev.*) {
            .edited => {
                self.active = 0;
                self.scroll.setOffset(.{ .x = 0, .y = 0 });
                cx.notify();
            },
            .escape => cx.emit(Close{}),
            .submitted => self.activateActive(cx),
            else => {},
        }
    }

    fn matches(query: []const u8, text: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, query, " \t");
        while (words.next()) |w| {
            if (std.ascii.findIgnoreCase(text, w) == null) return false;
        }
        return true;
    }

    /// Entries for the current query (actions first, then chats).
    fn entries(self: *Palette, cx: anytype, out: *std.ArrayList(Entry), arena: std.mem.Allocator) void {
        const query = std.mem.trim(u8, self.search.read(cx).text(), " ");
        const dark = ui.theme.get(cx).appearance.isDark();
        const acts = [_]struct { Entry, []const u8 }{
            .{ .new_chat, "New chat" },     .{ .new_project, "New project" },
            .{ .settings, "Open settings" }, if (dark) .{ .theme_light, "Switch to light theme" } else .{ .theme_dark, "Switch to dark theme" },
        };
        for (acts) |a| if (matches(query, a[1])) out.append(arena, a[0]) catch {};
        for (self.chat_ids.items) |c| self.gpa.free(c);
        self.chat_ids.clearRetainingCapacity();
        const ws = self.state.read(cx).workspace.read(cx);
        var chats: std.ArrayList(*const engine.protocol.Chat) = .empty;
        defer chats.deinit(arena);
        for (ws.chats()) |*c| {
            if (c.parentChatId != null) continue;
            const project = if (ws.spaceForChat(c)) |s| view.spaceDisplayName(s) else "~";
            const hay = std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{ c.title orelse "New session", project, ws.deviceName(c.deviceId) orelse "", if (c.sourceContext) |sc| sc.branch else "" }) catch continue;
            defer if (arena.ptr == self.gpa.ptr) self.gpa.free(hay);
            if (matches(query, hay)) chats.append(arena, c) catch {};
        }
        std.sort.block(*const engine.protocol.Chat, chats.items, {}, struct {
            fn lt(_: void, a: *const engine.protocol.Chat, b: *const engine.protocol.Chat) bool {
                const ka = a.lastMessageAt orelse a.createdAt;
                const kb = b.lastMessageAt orelse b.createdAt;
                const o = std.mem.order(u8, kb, ka);
                return if (o != .eq) o == .lt else std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lt);
        for (chats.items, 0..) |c, i| {
            if (i >= history_limit) break;
            const id = self.gpa.dupe(u8, c.id) catch continue;
            self.chat_ids.append(self.gpa, id) catch {
                self.gpa.free(id);
                continue;
            };
            out.append(arena, .{ .chat = self.chat_ids.items.len - 1 }) catch {};
        }
    }

    fn activateEntry(self: *Palette, e: Entry, cx: *Context(Palette)) void {
        const id: ?[]const u8 = switch (e) {
            .chat => |i| if (i < self.chat_ids.items.len) self.chat_ids.items[i] else return,
            else => null,
        };
        cx.emit(Activate{ .entry = e, .chat_id = id });
    }

    fn activateActive(self: *Palette, cx: *Context(Palette)) void {
        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(self.gpa);
        self.entries(cx, &list, self.gpa);
        if (self.active < list.items.len) self.activateEntry(list.items[self.active], cx);
    }

    fn onKey(self: *Palette, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(Palette)) void {
        const key = ev.keystroke.key;
        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(self.gpa);
        self.entries(cx, &list, self.gpa);
        const n = list.items.len;
        if (std.mem.eql(u8, key, "down") or std.mem.eql(u8, key, "up")) {
            if (n > 0) {
                self.active = if (key[0] == 'd') (self.active + 1) % n else (self.active + n - 1) % n;
                self.scroll.scrollToItem(self.active);
                cx.notify();
            }
        } else if (std.mem.eql(u8, key, "enter")) {
            if (self.active < n) self.activateEntry(list.items[self.active], cx);
        } else if (std.mem.eql(u8, key, "escape")) {
            cx.emit(Close{});
        } else return;
        cx.stopPropagation();
    }

    fn onHoverRow(self: *Palette, ix: usize, _: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(Palette)) void {
        if (self.active != ix) {
            self.active = ix;
            cx.notify();
        }
    }

    fn onClickRow(self: *Palette, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Palette)) void {
        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(self.gpa);
        self.entries(cx, &list, self.gpa);
        if (ix < list.items.len) self.activateEntry(list.items[ix], cx);
    }

    fn onOutside(_: *Palette, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Palette)) void {
        cx.emit(Close{});
    }

    fn highlighted(text: []const u8, query: []const u8, theme: *const Theme) zpui.AnyElement {
        const q = std.mem.trim(u8, query, " ");
        if (q.len == 0) return zpui.intoAnyElement(text);
        var hl: std.ArrayList(zpui.Highlight) = .empty;
        const arena = zpui.window.arena_mod.frameAllocator();
        var words = std.mem.tokenizeAny(u8, q, " \t");
        while (words.next()) |w| {
            if (std.ascii.findIgnoreCase(text, w)) |at| {
                hl.append(arena, .{ .start = at, .end = at + w.len, .style = .{ .color = theme.code_text, .background_color = theme.code_wash } }) catch {};
            }
        }
        if (hl.items.len == 0) return zpui.intoAnyElement(text);
        std.sort.block(zpui.Highlight, hl.items, {}, struct {
            fn lt(_: void, a: zpui.Highlight, b: zpui.Highlight) bool {
                return a.start < b.start;
            }
        }.lt);
        // Drop overlaps (the text element wants sorted, disjoint ranges).
        var kept: usize = 0;
        for (hl.items) |h| {
            if (kept > 0 and h.start < hl.items[kept - 1].end) continue;
            hl.items[kept] = h;
            kept += 1;
        }
        return zpui.intoAnyElement(zpui.styledText(text).withHighlights(hl.items[0..kept]));
    }

    fn chatRow(self: *Palette, c: *const engine.protocol.Chat, selected: bool, query: []const u8, theme: *const Theme, cx: anytype) zpui.Div {
        const ws = self.state.read(cx).workspace.read(cx);
        const prefs = prefs_mod.get(cx);
        const now = prefs.now(ws.io);
        const space = ws.spaceForChat(c);
        const project: []const u8 = if (space) |s| view.spaceDisplayName(s) else if (c.spaceId == null) "~" else "?";
        const folder = if (ws.deviceName(c.deviceId)) |d| zpui.fmt("{s} @ {s}", .{ project, d }) else project;
        const then = model.time.parseOpt(c.lastMessageAt) orelse model.time.parseOpt(c.createdAt) orelse now;
        var buf: [16]u8 = undefined;
        const ago = zpui.fmt("{s}", .{view.formatTimeAgo(&buf, then, now)});
        const status = ws.displayStatusFor(c, now);
        const branch: ?[]const u8 = if (c.sourceContext) |sc| (if (std.mem.trim(u8, sc.branch, " ").len > 0) sc.branch else null) else null;
        const title = view.singleLine(zpui.window.arena_mod.frameAllocator(), c.title orelse "New session") catch "New session";
        const sub = theme.text_muted;
        const corner: zpui.AnyElement = if (status == .completed)
            zpui.intoAnyElement(div().flex().itemsCenter().gap(px(4)).child(icon.of(.check, 11, sidebar_mod.statusColor(status, theme)))
                .child(div().textSize(ui.rems(10)).fontWeight(500).textColor(sidebar_mod.statusColor(status, theme)).child("Done")))
        else
            zpui.intoAnyElement(div().textSize(ui.rems(10)).fontWeight(500).lineHeight(px(14)).child(ago));
        var row = div().h(px(sidebar_mod.rowHeight(false, true, branch != null, false))).flex().flexCol().gap(px(2))
            .rounded(px(ui.popover.palette_item_radius)).px(px(8)).py(px(6))
            .textColor(theme.text)
            .bg(if (selected) ui.theme.cardSelectedBg(theme) else theme.wash(0))
            .child(div().wFull().flex().flexRow().itemsCenter().gap(px(8))
                .child(div().flex1().minW0().flex().textSize(ui.rems(11)).lineHeight(px(14)).textColor(sub).whitespaceNowrap().overflowHidden().child(highlighted(folder, query, theme)))
                .child(div().flexNone().h(px(14)).flex().itemsCenter().textColor(sub).child(corner)));
        var title_line = div().wFull().flex().flexRow().itemsCenter().gap(px(8));
        if (c.config) |cfg| title_line = title_line.child(icon.harness(cfg.harness, 13, sub, 0.8));
        title_line = title_line.child(div().flex1().minW0().textSize(ui.rems(13)).lineHeight(px(17)).whitespaceNowrap().overflowHidden().child(highlighted(title, query, theme)));
        row = row.child(title_line);
        if (branch) |b| row = row.child(div().wFull().flex().flexRow().itemsCenter().gap(px(4))
            .child(icon.of(.git_branch, 11, sub))
            .child(div().minW0().textSize(ui.rems(11)).lineHeight(px(14)).textColor(sub).whitespaceNowrap().overflowHidden().child(highlighted(b, query, theme))));
        return row;
    }

    pub fn render(self: *Palette, window: *Window, cx: *Context(Palette)) zpui.AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).forPopup());
        const arena = zpui.window.arena_mod.frameAllocator();
        var list: std.ArrayList(Entry) = .empty;
        self.entries(cx, &list, arena);
        if (list.items.len > 0) self.active = @min(self.active, list.items.len - 1);
        const query = self.search.read(cx).text();
        const vp = window.viewportSize();
        const ws = self.state.read(cx).workspace.read(cx);

        var results = div().id("command-results").minH0().maxH(px(std.math.clamp(vp.height - 180, 100, 360)))
            .overflowYScroll().trackScroll(self.scroll).flex().flexCol().gap(px(2));
        var action_count: usize = 0;
        for (list.items) |e| switch (e) {
            .chat => {},
            else => action_count += 1,
        };
        for (list.items, 0..) |e, ix| {
            const row_label: []const u8 = switch (e) {
                .chat => |ci| if (ws.chat(self.chat_ids.items[ci])) |c| c.title orelse "New session" else "",
                .new_chat => "New chat",
                .new_project => "New project",
                .settings => "Open settings",
                .theme_light => "Switch to light theme",
                .theme_dark => "Switch to dark theme",
            };
            var row = div().id(.{ "command-result", ix }).role(.button).ariaLabel(row_label).flexNone()
                .onMouseMove(cx.listenerWith(ix, Palette.onHoverRow))
                .onClick(cx.listenerWith(ix, Palette.onClickRow));
            if (ix == 0) row = row.pt(px(8));
            if (ix + 1 == list.items.len) row = row.pb(px(8));
            if (ix == action_count and action_count > 0) row = row.child(div().wFull().h(px(1)).my(px(8)).bg(theme.border.opacity(0.6)));
            const content: zpui.AnyElement = switch (e) {
                .chat => |ci| blk: {
                    const c = ws.chat(self.chat_ids.items[ci]) orelse break :blk zpui.empty();
                    break :blk zpui.intoAnyElement(self.chatRow(c, ix == self.active, query, theme, cx));
                },
                else => blk: {
                    const label: []const u8, const glyph: icon.Icon, const hint: ?[]const u8 = switch (e) {
                        .new_chat => .{ "New chat", .pen_new_square, zpui.fmt("{s}N", .{mod()}) },
                        .new_project => .{ "New project", .folder, zpui.fmt("{s}Shift+N", .{mod()}) },
                        .settings => .{ "Open settings", .settings, zpui.fmt("{s},", .{mod()}) },
                        .theme_light => .{ "Switch to light theme", .sun, null },
                        .theme_dark => .{ "Switch to dark theme", .moon, null },
                        .chat => unreachable,
                    };
                    break :blk zpui.intoAnyElement(ui.popover.menuRow(theme, ix == self.active)
                        .rounded(px(ui.popover.palette_item_radius)).minH(px(30)).py(px(4))
                        .child(icon.of(glyph, 16, theme.text_muted))
                        .child(div().flex1().minW0().child(highlighted(label, query, theme)))
                        .child(if (hint) |h| ui.popover.kbdHint(theme, h) else null));
                },
            };
            results = results.child(row.child(div().px(px(8)).child(content)));
        }
        if (list.items.len == 0) results = results.child(div().wFull().py(px(24)).px(px(16)).flex().flexCol().itemsCenter().gap(px(6))
            .textSize(ui.rems(13)).child("No results")
            .child(div().textColor(theme.text_muted).child("Try a command, chat title, project, or device.")));

        const hairline = theme.hairline(0.06);
        const card = div().id("command-palette").trackFocus(self.focus).keyContext("CommandPalette")
            .captureKeyDown(cx.listener(Palette.onKey))
            .onMouseDownOut(cx.listener(Palette.onOutside))
            .w(px(@min(560, vp.width - 32))).flex().flexCol().rounded(px(16))
            .border1().borderColor(theme.onGlassBorder(theme.border)) // [liquid-glass]
            .bg(ui.popover.surfaceBg(theme)).textColor(theme.text)
            .fontFamily(theme.font_sans).textSize(ui.rems(13))
            .child(div().minH(px(44)).flexNone().px(px(16)).py(px(8)).flex().itemsCenter().gap(px(10))
                .borderB1().borderColor(hairline)
                .child(icon.of(.palette_search, 16, theme.text_muted))
                .child(div().flex1().minW0().textSize(ui.rems(14)).child(self.search))
                .child(ui.popover.kbdHint(theme, zpui.fmt("{s}K", .{mod()}))))
            .child(ui.effects.edgeFaded(results, .{ .band = results_fade_band, .top = true, .bottom = true, .scroll = self.scroll }))
            .child(div().flexNone().px(px(16)).py(px(7)).borderT1().borderColor(hairline)
                .flex().flexWrap().itemsCenter().gap(px(12))
                .child(keyHint(theme, "↑ ↓", "Navigate"))
                .child(keyHint(theme, "↵", "Select"))
                .child(keyHint(theme, "Esc", "Close")));
        const card_el = if (!theme.isFrost()) card.shadowLg() else card;
        return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 })
            .child(div().occlude().w(px(vp.width)).h(px(vp.height))
            .bg(zt.theme.scrimFor(theme.appearance, 0.35))
            .flex().itemsCenter().justifyCenter()
            // `palette_overlay`: no entrance motion (Rust mounts the card as is).
            .child(ui.effects.frosted(16, zt.layout.menu_blur, card_el)))).withPriority(2));
    }
};

fn keyHint(theme: *const Theme, keys: []const u8, label: []const u8) zpui.Div {
    return div().flex().itemsCenter().gap(px(5))
        .child(ui.popover.kbdHint(theme, keys))
        .child(div().textSize(ui.rems(10)).textColor(theme.text_muted).child(label));
}
