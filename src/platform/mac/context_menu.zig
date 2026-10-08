//! macOS native context menus (`Window.VTable.showContextMenu`, zpui.showContextMenu):
//! an NSMenu built from `platform.ContextMenuRequest` and popped up with
//! `popUpMenuPositioningItem:atLocation:inView:` in the window's content view.
//!
//! * The menu is built (every string, icon and state copied into AppKit objects) during
//!   `show`, then popped up from a run-loop timer (`performSelector:withObject:afterDelay:`)
//!   once the current event is handled: zpui is never inside an app update or an input
//!   dispatch while the menu tracks.
//! * Tracking runs AppKit's nested loop in `NSEventTrackingRunLoopMode`. The display link
//!   and the app's dispatcher both deliver through the main GCD queue, which is serviced
//!   in every common mode, so frames keep rendering underneath; because the popup runs
//!   from a timer rather than from a main-queue block, the queue is not blocked by it.
//! * Native views a frame detaches while the menu tracks are kept alive until tracking
//!   ends (native_views.zig `retired` / `releaseRetired`, as for native controls).
//! * Every item targets one `ZPUIContextMenu` object (the menu's owner); its action
//!   records the item's tag. When the popup returns, `done` runs once with that tag or
//!   null (dismissed). If AppKit reports a selection whose action has not arrived yet,
//!   the completion waits one more run-loop turn for it.
//! * Icons are coverage masks turned into template NSImages (tinted by the menu, white
//!   on the selection) at the window's scale. Destructive items are system red; headers
//!   use `+[NSMenuItem sectionHeaderWithTitle:]` (macOS 14+, else a disabled item);
//!   check marks map to NSControlStateValueOn / Mixed.
//! * `dark` pins the menu's NSAppearance (DarkAqua / Aqua) to the app theme.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const platform = @import("../platform.zig");
const window_mod = @import("window.zig");
const native_views = @import("native_views.zig");
const menu_bar = @import("menu.zig");

const MacWindow = window_mod.MacWindow;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;
const CGFloat = ak.CGFloat;
const NSPoint = ak.NSPoint;
const NSSize = ak.NSSize;

const state_ivar = "zpuiMenuState";
/// MacWindow's back-pointer on its content view (window.zig `state_ivar`).
const window_ivar = "zpuiWindow";
const pick_selector = "zpuiContextMenuPick:";
const popup_selector = "zpuiContextMenuPopUp:";
const finish_selector = "zpuiContextMenuFinish:";

const State = struct {
    gpa: std.mem.Allocator,
    /// The window's content view (retained): where the menu pops up, and how the window
    /// is found again (it may close while the menu is queued or open).
    view: id,
    menu: id,
    /// Top-left of the menu in the view's (unflipped) coordinates.
    location: NSPoint,
    done: platform.ContextMenuDone,
    selected: ?u32 = null,
    finished: bool = false,
};

var owner_class: ?*objc.Class = null;

fn ownerClass() *objc.Class {
    if (owner_class) |c| return c;
    const c = blk: {
        const b = objc.ClassBuilder.init("NSObject", "ZPUIContextMenu") orelse break :blk objc.getClass("ZPUIContextMenu").?;
        _ = b.addPointerIvar(state_ivar);
        _ = b.addMethod(pick_selector, &pick, "v@:@");
        _ = b.addMethod(popup_selector, &popUp, "v@:@");
        _ = b.addMethod(finish_selector, &finishLater, "v@:@");
        break :blk b.register();
    };
    owner_class = c;
    return c;
}

fn stateOf(owner: id) ?*State {
    return @ptrCast(@alignCast(objc.getIvar(owner, state_ivar)));
}

fn windowOf(view: id) ?*MacWindow {
    const w: *MacWindow = @ptrCast(@alignCast(objc.getIvar(view, window_ivar) orelse return null));
    return if (w.closed) null else w;
}

pub fn show(w: *MacWindow, request: platform.ContextMenuRequest, done: platform.ContextMenuDone) bool {
    if (w.closed or request.items.len == 0) return false;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const st = w.gpa.create(State) catch return false;
    const owner = ownerClass().msg(id, "new", .{});
    objc.setIvar(owner, state_ivar, st);
    const menu = buildMenu(owner, request.items);
    if (request.dark) |dark| {
        const name = objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
        menu.msg(void, "setAppearance:", .{ak.class("NSAppearance").msg(?id, "appearanceNamed:", .{name})});
    }
    const height = ak.bounds(w.native_view).size.height;
    st.* = .{
        .gpa = w.gpa,
        .view = w.native_view.retain(),
        .menu = menu.retain(),
        .location = .{ .x = request.position.x, .y = height - @as(CGFloat, request.position.y) },
        .done = done,
    };
    // After the current event (a timer: default run-loop mode). The run loop retains
    // `owner` until the selector ran; ours goes now.
    owner.msg(void, "performSelector:withObject:afterDelay:", .{ objc.sel(popup_selector), @as(?id, null), @as(f64, 0) });
    owner.release();
    return true;
}

fn popUp(this: id, _: SEL, _: ?id) callconv(.c) void {
    const st = stateOf(this) orelse return;
    if (windowOf(st.view) == null) return complete(this, st);
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const chose = st.menu.msg(BOOL, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(?id, null), st.location, st.view });
    if (objc.fromBOOL(chose) and st.selected == null) {
        // The item's action is still on its way: finish on the next turn.
        this.msg(void, "performSelector:withObject:afterDelay:", .{ objc.sel(finish_selector), @as(?id, null), @as(f64, 0) });
        return;
    }
    complete(this, st);
}

fn finishLater(this: id, _: SEL, _: ?id) callconv(.c) void {
    const st = stateOf(this) orelse return;
    complete(this, st);
}

fn pick(this: id, _: SEL, sender: id) callconv(.c) void {
    const st = stateOf(this) orelse return;
    if (st.finished) return;
    const tag = sender.msg(NSInteger, "tag", .{});
    if (tag >= 0) st.selected = @intCast(tag);
}

/// Report the outcome once and free everything.
fn complete(owner: id, st: *State) void {
    if (st.finished) return;
    st.finished = true;
    objc.setIvar(owner, state_ivar, null);
    const view = st.view;
    defer view.release();
    // Items keep `owner` as their (weak) target: detach them before it goes away.
    clearTargets(st.menu);
    st.menu.release();
    const done = st.done;
    const selected = st.selected;
    st.gpa.destroy(st);
    done.func(done.ctx, selected);
    if (windowOf(view)) |w| native_views.releaseRetired(w);
}

fn clearTargets(menu: id) void {
    const n = menu.msg(NSInteger, "numberOfItems", .{});
    var i: NSInteger = 0;
    while (i < n) : (i += 1) {
        const item = menu.msg(?id, "itemAtIndex:", .{i}) orelse continue;
        item.msg(void, "setTarget:", .{@as(?id, null)});
        if (item.msg(?id, "submenu", .{})) |sub| clearTargets(sub);
    }
}

fn str(s: []const u8) id {
    return ak.nsString(s);
}

/// A new autoreleased menu holding `items`.
fn buildMenu(owner: id, items: []const platform.ContextMenuItem) id {
    const menu = ak.class("NSMenu").msg(id, "alloc", .{}).msg(id, "initWithTitle:", .{str("")}).autorelease();
    // Our `disabled` flags are the truth (no responder-chain validation).
    menu.msg(void, "setAutoenablesItems:", .{NO});
    for (items) |it| menu.msg(void, "addItem:", .{buildItem(owner, it)});
    return menu;
}

fn buildItem(owner: id, it: platform.ContextMenuItem) id {
    const NSMenuItem = ak.class("NSMenuItem");
    switch (it.kind) {
        .separator => return NSMenuItem.msg(id, "separatorItem", .{}),
        .header => {
            if (objc.fromBOOL(NSMenuItem.msg(BOOL, "respondsToSelector:", .{objc.sel("sectionHeaderWithTitle:")})))
                return NSMenuItem.msg(id, "sectionHeaderWithTitle:", .{str(it.label)});
            const h = NSMenuItem.msg(id, "alloc", .{}).msg(id, "initWithTitle:action:keyEquivalent:", .{ str(it.label), @as(?SEL, null), str("") }).autorelease();
            h.msg(void, "setEnabled:", .{NO});
            return h;
        },
        .submenu => {
            const holder = NSMenuItem.msg(id, "alloc", .{}).msg(id, "initWithTitle:action:keyEquivalent:", .{ str(it.label), @as(?SEL, null), str("") }).autorelease();
            const sub = buildMenu(owner, it.children);
            sub.msg(void, "setTitle:", .{str(it.label)});
            holder.msg(void, "setSubmenu:", .{sub});
            if (it.disabled) holder.msg(void, "setEnabled:", .{NO});
            if (it.icon) |icon| if (templateImage(icon)) |img| holder.msg(void, "setImage:", .{img});
            return holder;
        },
        .action => {},
    }
    var key_buf: [8]u8 = undefined;
    var key: []const u8 = "";
    var mask: NSUInteger = 0;
    if (it.shortcut) |sc| {
        key = menu_bar.keyToNative(sc.key, &key_buf);
        const M = ak.NSEventModifierFlags;
        if (sc.modifiers.platform) mask |= M.command;
        if (sc.modifiers.control) mask |= M.control;
        if (sc.modifiers.alt) mask |= M.option;
        if (sc.modifiers.shift) mask |= M.shift;
    }
    const item = NSMenuItem.msg(id, "alloc", .{}).msg(id, "initWithTitle:action:keyEquivalent:", .{
        str(it.label), objc.sel(pick_selector), str(key),
    }).autorelease();
    if (key.len > 0) {
        if (ak.osAtLeast(12, 0, 0)) item.msg(void, "setAllowsAutomaticKeyEquivalentLocalization:", .{NO});
        item.msg(void, "setKeyEquivalentModifierMask:", .{mask});
    }
    item.msg(void, "setTarget:", .{owner});
    item.msg(void, "setTag:", .{@as(NSInteger, @intCast(it.tag))});
    switch (it.check) {
        .off => {},
        .on => item.msg(void, "setState:", .{@as(NSInteger, 1)}),
        .mixed => item.msg(void, "setState:", .{@as(NSInteger, -1)}),
    }
    if (it.disabled) item.msg(void, "setEnabled:", .{NO});
    if (it.destructive) item.msg(void, "setAttributedTitle:", .{destructiveTitle(it.label)});
    if (it.icon) |icon| if (templateImage(icon)) |img| item.msg(void, "setImage:", .{img});
    return item;
}

/// `label` in the system red at the menu font (an attributed title replaces the font).
fn destructiveTitle(label: []const u8) id {
    const color = ak.class("NSColor").msg(id, "systemRedColor", .{});
    const font = ak.class("NSFont").msg(id, "menuFontOfSize:", .{@as(CGFloat, 0)});
    // NSForegroundColorAttributeName / NSFontAttributeName.
    var keys = [_]id{ objc.nsString("NSColor"), objc.nsString("NSFont") };
    var values = [_]id{ color, font };
    const attrs = ak.class("NSDictionary").msg(id, "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(NSUInteger, 2) });
    return ak.class("NSAttributedString").msg(id, "alloc", .{}).msg(id, "initWithString:attributes:", .{ str(label), attrs }).autorelease();
}

/// A template NSImage (black + coverage alpha) sized in points (autoreleased).
fn templateImage(icon: platform.ContextMenuIcon) ?id {
    if (icon.width == 0 or icon.height == 0 or icon.alpha.len < @as(usize, icon.width) * icon.height) return null;
    const w: NSInteger = @intCast(icon.width);
    const h: NSInteger = @intCast(icon.height);
    const rep = ak.class("NSBitmapImageRep").msg(id, "alloc", .{}).msg(?id, "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), w,   h,                                     @as(NSInteger, 8), @as(NSInteger, 4),
        YES,                    NO,  objc.nsString("NSDeviceRGBColorSpace"), w * 4,             @as(NSInteger, 32),
    }) orelse return null;
    defer rep.release();
    const data: [*]u8 = rep.msg(?[*]u8, "bitmapData", .{}) orelse return null;
    // Premultiplied RGBA: black with the mask as alpha.
    for (icon.alpha[0 .. icon.width * icon.height], 0..) |a, i| {
        data[i * 4 + 0] = 0;
        data[i * 4 + 1] = 0;
        data[i * 4 + 2] = 0;
        data[i * 4 + 3] = a;
    }
    const scale: CGFloat = if (icon.scale > 0) icon.scale else 1;
    const size: NSSize = .{ .width = @as(CGFloat, @floatFromInt(icon.width)) / scale, .height = @as(CGFloat, @floatFromInt(icon.height)) / scale };
    rep.msg(void, "setSize:", .{size});
    const img = ak.class("NSImage").msg(id, "alloc", .{}).msg(id, "initWithSize:", .{size}).autorelease();
    img.msg(void, "addRepresentation:", .{rep});
    img.msg(void, "setTemplate:", .{YES});
    return img;
}
