//! macOS application menu bar (zui `gpui_macos` `create_menu_bar` / `create_menu_item` /
//! `handle_menu_item` / `validate_menu_item` / `menu_will_open`).
//!
//! Every action item targets the responder chain (`target` nil) with selector
//! `handleZpuiMenuItem:` — or `cut:` / `copy:` / `paste:` / `selectAll:` for items with an
//! `OsAction`, so native text fields (save panels, a focused WKWebView) handle them first.
//! The chain ends at the app delegate, which implements all of them and reports the item's
//! `tag` through `PlatformCallbacks.menu_action`; `validateMenuItem:` asks
//! `PlatformCallbacks.validate_menu`. Menus named "Window" / "Help" become NSApp's windows /
//! help menus; a `.services` system submenu becomes the Services menu.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const pf = @import("../platform.zig");

const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const NSInteger = ak.NSInteger;
const NSUInteger = ak.NSUInteger;

pub const handle_selector = "handleZpuiMenuItem:";

/// Build the main menu (autoreleased). `delegate` becomes every menu's delegate
/// (`menuWillOpen:`).
pub fn build(menus: []const pf.Menu, delegate: id) id {
    const app = ak.sharedApp();
    const bar = newMenu("");
    bar.msg(void, "setDelegate:", .{delegate});
    for (menus) |m| {
        const menu = newMenu(m.name);
        menu.msg(void, "setDelegate:", .{delegate});
        for (m.items) |item| menu.msg(void, "addItem:", .{buildItem(item, delegate)});
        const holder = ak.class("NSMenuItem").msg(id, "new", .{}).autorelease();
        holder.msg(void, "setTitle:", .{ak.nsString(m.name)});
        holder.msg(void, "setSubmenu:", .{menu});
        if (m.disabled) holder.msg(void, "setEnabled:", .{objc.NO});
        bar.msg(void, "addItem:", .{holder});
        if (std.mem.eql(u8, m.name, "Window")) app.msg(void, "setWindowsMenu:", .{menu});
        if (std.mem.eql(u8, m.name, "Help")) app.msg(void, "setHelpMenu:", .{menu});
    }
    return bar;
}

/// A standalone menu (status item / tray) from `items` (autoreleased).
pub fn buildMenu(items: []const pf.MenuItem, delegate: id) id {
    const menu = newMenu("");
    menu.msg(void, "setDelegate:", .{delegate});
    menu.msg(void, "setAutoenablesItems:", .{objc.NO});
    for (items) |item| menu.msg(void, "addItem:", .{buildItem(item, delegate)});
    return menu;
}

fn newMenu(title: []const u8) id {
    return ak.class("NSMenu").msg(id, "alloc", .{}).msg(id, "initWithTitle:", .{ak.nsString(title)}).autorelease();
}

fn buildItem(item: pf.MenuItem, delegate: id) id {
    switch (item) {
        .separator => return ak.class("NSMenuItem").msg(id, "separatorItem", .{}),
        .action => |a| {
            const selector: SEL = if (a.os_action) |os| switch (os) {
                .cut => objc.sel("cut:"),
                .copy => objc.sel("copy:"),
                .paste => objc.sel("paste:"),
                .select_all => objc.sel("selectAll:"),
                // No native text view enables undo:/redo: for us (gpui does the same).
                .undo, .redo => objc.sel(handle_selector),
            } else objc.sel(handle_selector);
            var key_buf: [8]u8 = undefined;
            var key: []const u8 = "";
            var mask: NSUInteger = 0;
            if (a.key_equivalent) |ke| {
                key = keyToNative(ke.key, &key_buf);
                const M = ak.NSEventModifierFlags;
                if (ke.modifiers.platform) mask |= M.command;
                if (ke.modifiers.control) mask |= M.control;
                if (ke.modifiers.alt) mask |= M.option;
                if (ke.modifiers.shift) mask |= M.shift;
            }
            const ns_item = ak.class("NSMenuItem").msg(id, "alloc", .{}).msg(id, "initWithTitle:action:keyEquivalent:", .{
                ak.nsString(a.name), selector, ak.nsString(key),
            }).autorelease();
            if (key.len > 0) {
                // Keep "⌘," on ⌘, everywhere (no per-layout relocalization; gpui, macOS 12+).
                if (ak.osAtLeast(12, 0, 0)) ns_item.msg(void, "setAllowsAutomaticKeyEquivalentLocalization:", .{objc.NO});
                ns_item.msg(void, "setKeyEquivalentModifierMask:", .{mask});
            }
            if (a.checked) ns_item.msg(void, "setState:", .{@as(NSInteger, 1)}); // NSControlStateValueOn
            if (a.disabled) ns_item.msg(void, "setEnabled:", .{objc.NO});
            ns_item.msg(void, "setTag:", .{@as(NSInteger, @intCast(a.tag))});
            return ns_item;
        },
        .submenu => |sm| {
            const holder = ak.class("NSMenuItem").msg(id, "new", .{}).autorelease();
            const sub = newMenu(sm.name);
            sub.msg(void, "setDelegate:", .{delegate});
            for (sm.items) |it| sub.msg(void, "addItem:", .{buildItem(it, delegate)});
            holder.msg(void, "setSubmenu:", .{sub});
            holder.msg(void, "setTitle:", .{ak.nsString(sm.name)});
            if (sm.disabled) holder.msg(void, "setEnabled:", .{objc.NO});
            return holder;
        },
        .system_menu => |sys| {
            const holder = ak.class("NSMenuItem").msg(id, "new", .{}).autorelease();
            const sub = newMenu(sys.name);
            sub.msg(void, "setDelegate:", .{delegate});
            holder.msg(void, "setSubmenu:", .{sub});
            holder.msg(void, "setTitle:", .{ak.nsString(sys.name)});
            switch (sys.kind) {
                .services => ak.sharedApp().msg(void, "setServicesMenu:", .{sub}),
            }
            return holder;
        },
    }
}

/// gpui key name → NSMenuItem key equivalent (gpui `key_to_native`).
pub fn keyToNative(key: []const u8, buf: *[8]u8) []const u8 {
    const named = [_]struct { []const u8, u21 }{
        .{ "space", ' ' },        .{ "backspace", 0x08 },   .{ "escape", 0x1b },      .{ "enter", '\r' },
        .{ "tab", '\t' },         .{ "up", 0xF700 },        .{ "down", 0xF701 },      .{ "left", 0xF702 },
        .{ "right", 0xF703 },     .{ "pageup", 0xF72C },    .{ "pagedown", 0xF72D },  .{ "home", 0xF729 },
        .{ "end", 0xF72B },       .{ "delete", 0xF728 },    .{ "insert", 0xF746 },
    };
    for (named) |n| if (std.mem.eql(u8, key, n[0])) {
        const len = std.unicode.utf8Encode(n[1], buf) catch return key;
        return buf[0..len];
    };
    if (key.len >= 2 and key[0] == 'f') {
        const num = std.fmt.parseInt(u21, key[1..], 10) catch return key;
        if (num >= 1 and num <= 35) {
            const len = std.unicode.utf8Encode(0xF704 + num - 1, buf) catch return key;
            return buf[0..len];
        }
    }
    return key;
}

/// `handleZpuiMenuItem:` / `cut:` / ... on the app delegate.
pub fn handle(callbacks: pf.PlatformCallbacks, item: id) void {
    const f = callbacks.menu_action orelse return;
    const tag = item.msg(NSInteger, "tag", .{});
    if (tag < 0) return;
    f(callbacks.ctx, @intCast(tag));
}

/// `validateMenuItem:` on the app delegate. Items we did not build (tag 0 is ours too, so
/// check the selector) keep AppKit's default (enabled).
pub fn validate(callbacks: pf.PlatformCallbacks, item: id) bool {
    const action = item.msg(?SEL, "action", .{}) orelse return true;
    if (!isOurs(action)) return true;
    const f = callbacks.validate_menu orelse return true;
    const tag = item.msg(NSInteger, "tag", .{});
    if (tag < 0) return false;
    return f(callbacks.ctx, @intCast(tag));
}

fn isOurs(action: SEL) bool {
    inline for (.{ handle_selector, "cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:" }) |name| {
        if (action == objc.cachedSel(name)) return true;
    }
    return false;
}

test "keyToNative maps gpui key names" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("q", keyToNative("q", &buf));
    try std.testing.expectEqualStrings(",", keyToNative(",", &buf));
    try std.testing.expectEqualStrings(" ", keyToNative("space", &buf));
    try std.testing.expectEqualStrings("\u{F700}", keyToNative("up", &buf));
    try std.testing.expectEqualStrings("\u{F70F}", keyToNative("f12", &buf));
}
