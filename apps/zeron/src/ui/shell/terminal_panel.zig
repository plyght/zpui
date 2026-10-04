//! The bottom terminal drawer (zeron `terminal/panel.rs` `TerminalPanel`):
//! per-chat tab sets under the main column, toggled with mod-j.
//!
//! - a 40px tab bar: 118px tabs (terminal glyph, live OSC title else
//!   "Terminal N" / the action's name, close ✕ on the selected tab,
//!   middle-click closes, exited tabs at 55%), `+` (New terminal) and the
//!   collapse chevron (Hide terminal);
//! - opening the drawer lazily creates the selected chat's first tab;
//!   switching chats shows that chat's own tabs (detach ≠ close); closing the
//!   last tab hides the drawer;
//! - Project Actions use the keyed API: `reserveTab` (a named placeholder
//!   before `RunProjectAction` replies), `attachReserved` (stream the
//!   engine's PTY into it), `failReserved` (a red failure line), `selectTab`.
//!
//! Each tab's body is a chrome-less `TerminalDock`: "+" tabs run the user's
//! shell on a local PTY in the chat's working directory (see
//! `terminal_dock.zig`); action tabs stream the engine PTY.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const ui = @import("../components/root.zig");
const terminal_dock = @import("terminal_dock.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const TerminalDock = terminal_dock.TerminalDock;

pub const tab_bar_height: f32 = terminal_dock.tab_bar_height;
pub const tab_width: f32 = terminal_dock.tab_width;

/// The drawer asks to be hidden (collapse chevron / last tab closed).
pub const Hide = terminal_dock.Hide;

const Tab = struct {
    key: u64,
    dock: Entity(TerminalDock),
};

const ChatTabs = struct {
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,
};

/// `active_after_close`.
pub fn activeAfterClose(active: usize, closed: usize, len_after: usize) usize {
    const shifted = if (closed < active) active - 1 else active;
    if (len_after == 0) return 0;
    return @min(shifted, len_after - 1);
}

pub const TerminalPanel = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    chats: std.StringHashMapUnmanaged(ChatTabs) = .empty,
    tab_seq: u64 = 0,
    open: bool = false,
    focus_pending: bool = false,

    pub const Events = .{Hide};

    pub fn init(state: Entity(model.AppState), cx: *Context(TerminalPanel)) !TerminalPanel {
        return .{ .gpa = cx.gpa(), .state = state.retain(cx) };
    }

    pub fn deinit(self: *TerminalPanel, app: *App) void {
        var it = self.chats.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.tabs.items) |t| t.dock.release(app);
            e.value_ptr.tabs.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.chats.deinit(self.gpa);
        self.state.release(app);
    }

    /// `panel_session_key`: the selected chat, or "" on the new-session canvas.
    pub fn selectedKey(self: *const TerminalPanel, cx: anytype) []const u8 {
        return self.state.read(cx).workspace.read(cx).selected_chat orelse "";
    }

    fn chatTabs(self: *TerminalPanel, chat: []const u8) ?*ChatTabs {
        const gop = self.chats.getOrPut(self.gpa, chat) catch return null;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, chat) catch {
                _ = self.chats.remove(chat);
                return null;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn find(self: *const TerminalPanel, chat: []const u8, key: u64) ?Entity(TerminalDock) {
        const tabs = self.chats.getPtr(chat) orelse return null;
        for (tabs.tabs.items) |t| if (t.key == key) return t.dock;
        return null;
    }

    /// `(key, title, exited)` of the selected chat's tabs (tests / a11y).
    pub fn tabCount(self: *const TerminalPanel, chat: []const u8) usize {
        const tabs = self.chats.getPtr(chat) orelse return 0;
        return tabs.tabs.items.len;
    }

    pub fn activeKey(self: *const TerminalPanel, chat: []const u8) ?u64 {
        const tabs = self.chats.getPtr(chat) orelse return null;
        if (tabs.active >= tabs.tabs.items.len) return null;
        return tabs.tabs.items[tabs.active].key;
    }

    /// `set_open`: opening lazily creates the selected chat's first tab;
    /// closing keeps every session alive.
    pub fn setOpen(self: *TerminalPanel, open: bool, window: *Window, cx: *Context(TerminalPanel)) void {
        if (open and !self.open) self.focus_pending = true;
        self.open = open;
        if (!open) self.focus_pending = false;
        if (open) self.ensureTab(window, cx);
    }

    /// `ensure_tab` (idempotent; called every frame while open so a chat
    /// switch gets its own first tab).
    fn ensureTab(self: *TerminalPanel, window: *Window, cx: *Context(TerminalPanel)) void {
        const chat = self.selectedKey(cx);
        if (self.chats.getPtr(chat)) |t| if (t.tabs.items.len > 0) return;
        self.openTab(chat, window, cx);
    }

    /// The working directory a fresh tab starts in (`terminal_open_cwd_for`).
    fn cwdFor(self: *const TerminalPanel, chat: []const u8, cx: anytype) ?[]const u8 {
        const ws = self.state.read(cx).workspace.read(cx);
        if (chat.len > 0) if (ws.chat(chat)) |c| return c.cwd orelse if (ws.spaceForChat(c)) |sp| sp.path else null;
        return if (ws.selectedSpaceRow()) |sp| sp.path else null;
    }

    /// `open_tab`: a fresh "Terminal N" running the user's shell.
    fn openTab(self: *TerminalPanel, chat_in: []const u8, window: *Window, cx: *Context(TerminalPanel)) void {
        const chat = self.gpa.dupe(u8, chat_in) catch return;
        defer self.gpa.free(chat);
        const tabs = self.chatTabs(chat) orelse return;
        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Terminal {d}", .{tabs.tabs.items.len + 1}) catch "Terminal";
        const io = self.state.read(cx).workspace.read(cx).io;
        const dock = cx.newWith(TerminalDock, TerminalDock.initTitled, .{ io, self.cwdFor(chat, cx), title, window }) catch |err| {
            std.log.warn("terminal: {t}", .{err});
            return;
        };
        {
            var l = dock.lease(cx);
            defer l.end();
            l.value.chrome = false;
        }
        self.tab_seq += 1;
        const t2 = self.chatTabs(chat) orelse return dock.release(cx);
        t2.tabs.append(self.gpa, .{ .key = self.tab_seq, .dock = dock }) catch return dock.release(cx);
        t2.active = t2.tabs.items.len - 1;
        self.focus_pending = true;
        cx.notify();
    }

    /// `reserve_tab_for_chat`: a named placeholder (no PTY) made the chat's
    /// active tab. Returns its key.
    pub fn reserveTab(self: *TerminalPanel, chat: []const u8, title: []const u8, cx: *Context(TerminalPanel)) ?u64 {
        const io = self.state.read(cx).workspace.read(cx).io;
        const dock = cx.newWith(TerminalDock, TerminalDock.initDetached, .{ io, title }) catch return null;
        const tabs = self.chatTabs(chat) orelse {
            dock.release(cx);
            return null;
        };
        self.tab_seq += 1;
        tabs.tabs.append(self.gpa, .{ .key = self.tab_seq, .dock = dock }) catch {
            dock.release(cx);
            return null;
        };
        tabs.active = tabs.tabs.items.len - 1;
        cx.notify();
        return self.tab_seq;
    }

    /// `attach_reserved_session`: false when the tab is gone (the caller
    /// closes the session).
    pub fn attachReserved(self: *TerminalPanel, chat: []const u8, key: u64, session: engine.protocol.TerminalSession, target: ?[]const u8, cx: *Context(TerminalPanel)) bool {
        const dock = self.find(chat, key) orelse return false;
        const es = self.state.read(cx).engine;
        return dock.update(cx, TerminalDock.attachEngine, .{ es, session, target });
    }

    /// `fail_reserved_tab`.
    pub fn failReserved(self: *TerminalPanel, chat: []const u8, key: u64, message: []const u8, cx: *Context(TerminalPanel)) void {
        const dock = self.find(chat, key) orelse return;
        dock.update(cx, TerminalDock.failReserved, .{message});
    }

    /// `select_tab_by_key` (the selected chat's strip).
    pub fn selectTab(self: *TerminalPanel, key: u64, cx: *Context(TerminalPanel)) void {
        const chat = self.selectedKey(cx);
        const tabs = self.chats.getPtr(chat) orelse return;
        for (tabs.tabs.items, 0..) |t, i| if (t.key == key) {
            tabs.active = i;
            self.focus_pending = true;
            cx.notify();
            return;
        };
    }

    /// `close_tab`: the engine PTY closes with it; closing the last tab
    /// hides the drawer.
    pub fn closeTab(self: *TerminalPanel, key: u64, cx: *Context(TerminalPanel)) void {
        const chat = self.selectedKey(cx);
        const tabs = self.chats.getPtr(chat) orelse return;
        const ix = for (tabs.tabs.items, 0..) |t, i| {
            if (t.key == key) break i;
        } else return;
        const tab = tabs.tabs.orderedRemove(ix);
        tabs.active = activeAfterClose(tabs.active, ix, tabs.tabs.items.len);
        const now_empty = tabs.tabs.items.len == 0;
        tab.dock.update(cx, TerminalDock.closeSession, .{});
        tab.dock.release(cx);
        if (now_empty and self.open) cx.emit(Hide{});
        cx.notify();
    }

    fn onTabClick(self: *TerminalPanel, key: u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TerminalPanel)) void {
        self.selectTab(key, cx);
    }

    fn onTabMiddle(self: *TerminalPanel, key: u64, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(TerminalPanel)) void {
        self.closeTab(key, cx);
    }

    fn onClose(self: *TerminalPanel, key: u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TerminalPanel)) void {
        cx.stopPropagation();
        self.closeTab(key, cx);
    }

    fn onNewTab(self: *TerminalPanel, _: *const zpui.ClickEvent, window: *Window, cx: *Context(TerminalPanel)) void {
        const chat = self.gpa.dupe(u8, self.selectedKey(cx)) catch return;
        defer self.gpa.free(chat);
        self.openTab(chat, window, cx);
    }

    fn onHide(_: *TerminalPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(TerminalPanel)) void {
        cx.emit(Hide{});
    }

    fn renderTabBar(self: *TerminalPanel, chat: []const u8, cx: *Context(TerminalPanel)) zpui.StatefulDiv {
        const theme = ui.theme.get(cx);
        var bar = div().id("terminal-tab-bar").h(px(tab_bar_height)).flexNone().flex().flexRow().itemsCenter()
            .gap(px(4)).pl(px(8)).pr(px(6)).borderB1().borderColor(theme.hairline(0.07));
        if (self.chats.getPtr(chat)) |tabs| for (tabs.tabs.items, 0..) |t, ix| {
            const selected = ix == tabs.active;
            const dock = t.dock.read(cx);
            const title = zpui.fmt("{s}", .{terminal_dock.displayTitle(dock)});
            const text_color = if (selected) theme.text else theme.text_muted.opacity(0.6);
            const glyph_alpha: f32 = if (selected) 0.8 else 0.6;
            var close = div().id(.{ "terminal-tab-close", t.key }).size(px(20)).flexNone().flex().itemsCenter().justifyCenter()
                .rounded(px(6)).cursorPointer().hover(sb.bg(theme.ink(0.09)))
                .tooltipWith(@as([]const u8, "Close terminal"), ui.tooltip.build)
                .onClick(cx.listenerWith(t.key, onClose))
                .child(ui.icon.of(.close, 12, theme.text_muted.opacity(0.8)));
            if (!selected) close = close.invisible();
            var tab = div().id(.{ "terminal-tab", t.key }).w(px(tab_width)).h(px(28)).flexNone()
                .flex().flexRow().itemsCenter().gap(px(6)).pl(px(8)).pr(px(4)).rounded(px(8))
                .textSize(px(12)).textColor(text_color).cursorPointer()
                .onClick(cx.listenerWith(t.key, onTabClick))
                .onMouseDown(.middle, cx.listenerWith(t.key, onTabMiddle))
                .child(ui.icon.of(.terminal, 16, text_color.opacity(glyph_alpha)))
                .child(div().flex1().minW0().truncate().whitespaceNowrap().child(title))
                .child(close);
            tab = if (selected) tab.bg(theme.ink(0.08)) else tab.hover(sb.bg(theme.element_hover));
            if (dock.exited) tab = tab.opacity(0.55);
            bar = bar.child(tab);
        };
        return bar
            .child(div().id("terminal-new-tab").size(px(28)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(8)).cursorPointer().hover(sb.bg(theme.ink(0.05)))
            .tooltipWith(@as([]const u8, "New terminal"), ui.tooltip.build)
            .onClick(cx.listener(onNewTab))
            .child(ui.icon.of(.plus, 16, theme.text_muted.opacity(0.6))))
            .child(div().flex1())
            .child(div().id("terminal-collapse").size(px(28)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(8)).cursorPointer().hover(sb.bg(theme.ink(0.05)))
            .tooltipWith(@as([]const u8, "Hide terminal"), ui.tooltip.build)
            .onClick(cx.listener(onHide))
            .child(ui.icon.of(.alt_arrow_down, 13, theme.text_muted.opacity(0.55))));
    }

    pub fn render(self: *TerminalPanel, window: *Window, cx: *Context(TerminalPanel)) zpui.Div {
        const theme = ui.theme.get(cx);
        if (self.open) self.ensureTab(window, cx);
        const chat = self.selectedKey(cx);
        var root = div().sizeFull().flex().flexCol().bg(theme.terminal.background).borderT1().borderColor(theme.border)
            .fontFamily(theme.font_sans)
            .child(self.renderTabBar(chat, cx));
        const tabs = self.chats.getPtr(chat);
        const active: ?Entity(TerminalDock) = if (tabs) |t| (if (t.active < t.tabs.items.len) t.tabs.items[t.active].dock else null) else null;
        if (active) |dock| {
            if (self.focus_pending and self.open) {
                self.focus_pending = false;
                window.focus(dock.read(cx).focusHandle());
            }
            root = root.child(div().flex1().minH0().child(dock));
        } else root = root.child(div().flex1().minH0());
        return root;
    }
};

test "active index tracks closes" {
    try std.testing.expectEqual(@as(usize, 1), activeAfterClose(2, 0, 3));
    try std.testing.expectEqual(@as(usize, 1), activeAfterClose(1, 1, 2));
    try std.testing.expectEqual(@as(usize, 1), activeAfterClose(2, 2, 2));
    try std.testing.expectEqual(@as(usize, 0), activeAfterClose(0, 0, 0));
}
