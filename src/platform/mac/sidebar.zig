//! macOS native sidebar (`WindowParams.sidebar`, `platform.SidebarState`): the window's
//! content view controller becomes an `NSSplitViewController` with
//!
//!   * a sidebar item (`+[NSSplitViewItem sidebarWithViewController:]`) whose view is an
//!     `NSScrollView` around a single-column `NSTableView` in the source-list style
//!     (`NSTableViewStyleSourceList`, default row size), and
//!   * a content item whose view (the "host") holds zpui's ZPUIView and its native
//!     children, so zpui's coordinate space, content size and native views are the
//!     detail pane's (`MacWindow.hostView`).
//!
//! AppKit draws whatever sidebar the running OS has: on macOS 26+ the floating Liquid
//! Glass pane, before that the full-height vibrant column; with a full-size content view
//! (`TitlebarOptions.appears_transparent`) the sidebar runs full height under the
//! titlebar (`allowsFullHeightLayout`). Rows are `NSTableCellView`s (an SF Symbol, or the
//! symbol on a colored badge like System Settings, and the title in the cell's text
//! field, so the table sizes the font and switches its color on selection).
//!
//! One `ZPUISidebarSource` per window is the table's data source and delegate; a user
//! selection calls `WindowCallbacks.sidebar_select` (main thread, from AppKit's event
//! handling). Programmatic selection (`set`) never reports back.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const platform = @import("../platform.zig");
const window_mod = @import("window.zig");

const MacWindow = window_mod.MacWindow;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;
const CGFloat = ak.CGFloat;
const NSRect = ak.NSRect;
const NSSize = ak.NSSize;

const log = std.log.scoped(.mac_sidebar);

const window_ivar = "zpuiWindow";

// NSView autoresizing masks.
const width_sizable: NSUInteger = 2;
const height_sizable: NSUInteger = 16;

pub const State = struct {
    split_vc: id,
    table: id,
    source: id,
    /// Copies of the shown rows (strings in `arena`).
    arena: std.heap.ArenaAllocator,
    items: []platform.SidebarItem = &.{},
    label: []const u8 = "",
    dark: ?bool = null,
    /// Set while `set` selects a row (no `sidebar_select` for it).
    suppress: bool = false,
};

var source_class: ?*objc.Class = null;
var row_class: ?*objc.Class = null;

fn registerClasses() void {
    if (source_class != null) return;
    source_class = blk: {
        const b = objc.ClassBuilder.init("NSObject", "ZPUISidebarSource") orelse break :blk objc.getClass("ZPUISidebarSource").?;
        _ = b.addPointerIvar(window_ivar);
        _ = b.addMethod("numberOfRowsInTableView:", &numberOfRows, "q@:@");
        _ = b.addMethod("tableView:viewForTableColumn:row:", &viewForRow, "@@:@@q");
        _ = b.addMethod("tableView:rowViewForRow:", &rowViewForRow, "@@:@q");
        _ = b.addMethod("tableViewSelectionDidChange:", &selectionDidChange, "v@:@");
        break :blk b.register();
    };
    row_class = blk: {
        const b = objc.ClassBuilder.init("NSTableRowView", "ZPUISidebarRowView") orelse break :blk objc.getClass("ZPUISidebarRowView").?;
        _ = b.addMethod("isEmphasized", &rowIsEmphasized, ak.enc_bool ++ "@:");
        break :blk b.register();
    };
}

fn windowOf(source: id) ?*MacWindow {
    const w: *MacWindow = @ptrCast(@alignCast(objc.getIvar(source, window_ivar) orelse return null));
    if (w.closed) return null;
    return w;
}

fn responds(obj: anytype, comptime selector: [:0]const u8) bool {
    return obj.msg(BOOL, "respondsToSelector:", .{objc.cachedSel(selector)}) == YES;
}

const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

/// Build the split view controller around `host` (zpui's detail view, already holding
/// the ZPUIView) and make it `native_window`'s content. Returns null (and leaves the
/// window alone) when AppKit lacks the pieces.
pub fn install(w: *MacWindow, opts: platform.SidebarOptions, host: id, content_size: NSSize) ?*State {
    registerClasses();
    const split_cls = objc.getClass("NSSplitViewController") orelse return null;
    const item_cls = objc.getClass("NSSplitViewItem") orelse return null;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();

    // The table: one column, no header, source-list style.
    const table = ak.class("NSTableView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{zero});
    defer table.release(); // the scroll view keeps it
    const column = ak.class("NSTableColumn").msg(id, "alloc", .{}).msg(id, "initWithIdentifier:", .{ak.nsString("zpui.sidebar")});
    column.msg(void, "setResizingMask:", .{@as(NSUInteger, 1)}); // NSTableColumnAutoresizingMask
    column.msg(void, "setWidth:", .{@as(CGFloat, opts.width)});
    table.msg(void, "addTableColumn:", .{column});
    column.release();
    table.msg(void, "setHeaderView:", .{@as(?id, null)});
    if (responds(table, "setStyle:")) {
        table.msg(void, "setStyle:", .{@as(NSInteger, 3)}); // NSTableViewStyleSourceList (11+)
    } else {
        table.msg(void, "setSelectionHighlightStyle:", .{@as(NSInteger, 1)}); // ...SourceList
    }
    table.msg(void, "setRowSizeStyle:", .{@as(NSInteger, -1)}); // NSTableViewRowSizeStyleDefault: the user's sidebar size
    // The one column follows the table's width (the sidebar's), so titles are not cut.
    table.msg(void, "setColumnAutoresizingStyle:", .{@as(NSUInteger, 4)}); // LastColumnOnly
    table.msg(void, "setAllowsEmptySelection:", .{NO});
    table.msg(void, "setAllowsMultipleSelection:", .{NO});
    table.msg(void, "setFocusRingType:", .{@as(NSUInteger, 1)}); // NSFocusRingTypeNone
    table.msg(void, "setAccessibilityLabel:", .{ak.nsString("Sidebar")});

    const source = source_class.?.msg(id, "new", .{});
    objc.setIvar(source, window_ivar, w);
    table.msg(void, "setDataSource:", .{source});
    table.msg(void, "setDelegate:", .{source});

    const scroll = ak.class("NSScrollView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = opts.width, .height = content_size.height } }});
    defer scroll.release();
    scroll.msg(void, "setDocumentView:", .{table});
    scroll.msg(void, "setHasVerticalScroller:", .{YES});
    scroll.msg(void, "setAutohidesScrollers:", .{YES});
    scroll.msg(void, "setDrawsBackground:", .{NO});
    scroll.msg(void, "setBorderType:", .{@as(NSUInteger, 0)}); // NSNoBorder
    scroll.msg(void, "setAutoresizingMask:", .{width_sizable | height_sizable});

    const sidebar_vc = ak.class("NSViewController").msg(id, "new", .{});
    defer sidebar_vc.release();
    sidebar_vc.msg(void, "setView:", .{scroll});
    const detail_vc = ak.class("NSViewController").msg(id, "new", .{});
    defer detail_vc.release();
    detail_vc.msg(void, "setView:", .{host});

    const split_vc = split_cls.msg(id, "new", .{});
    const sidebar_item = item_cls.msg(id, "sidebarWithViewController:", .{sidebar_vc});
    sidebar_item.msg(void, "setMinimumThickness:", .{@as(CGFloat, opts.min_width)});
    sidebar_item.msg(void, "setMaximumThickness:", .{@as(CGFloat, opts.max_width)});
    sidebar_item.msg(void, "setCanCollapse:", .{objc.toBOOL(opts.collapsible)});
    if (responds(sidebar_item, "setCanCollapseFromWindowResize:")) sidebar_item.msg(void, "setCanCollapseFromWindowResize:", .{objc.toBOOL(opts.collapsible)});
    if (responds(sidebar_item, "setAllowsFullHeightLayout:")) sidebar_item.msg(void, "setAllowsFullHeightLayout:", .{YES});
    // No line under the traffic lights across the sidebar (System Settings).
    if (responds(sidebar_item, "setTitlebarSeparatorStyle:")) sidebar_item.msg(void, "setTitlebarSeparatorStyle:", .{@as(NSInteger, 1)}); // NSTitlebarSeparatorStyleNone
    const detail_item = item_cls.msg(id, "splitViewItemWithViewController:", .{detail_vc});
    split_vc.msg(void, "addSplitViewItem:", .{sidebar_item});
    split_vc.msg(void, "addSplitViewItem:", .{detail_item});

    const split_view = split_vc.msg(id, "view", .{});
    split_view.msg(void, "setFrame:", .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = content_size }});
    w.native_window.msg(void, "setContentViewController:", .{split_vc});
    // Setting a content view controller may resize the window to the controller's view.
    w.native_window.msg(void, "setContentSize:", .{content_size});
    split_view.msg(void, "layoutSubtreeIfNeeded", .{});
    if (split_vc.msg(?id, "splitView", .{})) |sv| sv.msg(void, "setPosition:ofDividerAtIndex:", .{ @as(CGFloat, opts.width), @as(NSInteger, 0) });

    const st = w.gpa.create(State) catch {
        source.release();
        split_vc.release();
        return null;
    };
    st.* = .{ .split_vc = split_vc, .table = table.retain(), .source = source, .arena = .init(w.gpa) };
    log.info("native sidebar: NSSplitViewController + source list ({d:.0} pt)", .{opts.width});
    return st;
}

pub fn deinit(w: *MacWindow) void {
    const st = w.sidebar orelse return;
    objc.setIvar(st.source, window_ivar, null);
    st.table.msg(void, "setDelegate:", .{@as(?id, null)});
    st.table.msg(void, "setDataSource:", .{@as(?id, null)});
    st.table.release();
    st.source.release();
    st.split_vc.release();
    st.arena.deinit();
    w.gpa.destroy(st);
    w.sidebar = null;
}

fn itemsEql(a: []const platform.SidebarItem, b: []const platform.SidebarItem) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.title, y.title) or !std.mem.eql(u8, x.symbol, y.symbol) or !std.meta.eql(x.badge, y.badge)) return false;
    }
    return true;
}

/// `platform.Window.setSidebar`.
pub fn set(w: *MacWindow, state: platform.SidebarState) void {
    const st = w.sidebar orelse return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    if (!std.meta.eql(st.dark, state.dark)) {
        st.dark = state.dark;
        // The whole window: the sidebar, the titlebar and the window background around a
        // floating sidebar follow the app theme together.
        const appearance: ?id = if (state.dark) |dark|
            ak.class("NSAppearance").msg(?id, "appearanceNamed:", .{objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua")})
        else
            null;
        w.native_window.msg(void, "setAppearance:", .{appearance});
    }
    if (!itemsEql(st.items, state.items) or !std.mem.eql(u8, st.label, state.label)) {
        _ = st.arena.reset(.retain_capacity);
        const a = st.arena.allocator();
        st.label = a.dupe(u8, state.label) catch "";
        st.items = a.alloc(platform.SidebarItem, state.items.len) catch &.{};
        for (state.items[0..st.items.len], st.items) |src, *dst| dst.* = .{
            .title = a.dupe(u8, src.title) catch "",
            .symbol = a.dupe(u8, src.symbol) catch "",
            .badge = src.badge,
        };
        st.table.msg(void, "setAccessibilityLabel:", .{ak.nsString(if (st.label.len > 0) st.label else "Sidebar")});
        st.suppress = true;
        st.table.msg(void, "sizeLastColumnToFit", .{});
        st.table.msg(void, "reloadData", .{});
        st.suppress = false;
    }
    const want: NSInteger = if (state.selected) |s| (if (s < st.items.len) @intCast(s) else -1) else -1;
    if (st.table.msg(NSInteger, "selectedRow", .{}) != want) {
        st.suppress = true;
        defer st.suppress = false;
        if (want < 0) {
            st.table.msg(void, "deselectAll:", .{@as(?id, null)});
        } else {
            const set_ = ak.class("NSIndexSet").msg(id, "indexSetWithIndex:", .{@as(NSUInteger, @intCast(want))});
            st.table.msg(void, "selectRowIndexes:byExtendingSelection:", .{ set_, NO });
            st.table.msg(void, "scrollRowToVisible:", .{want});
        }
    }
}

// ---- data source / delegate ---------------------------------------------------------------

fn numberOfRows(this: id, _: SEL, _: id) callconv(.c) NSInteger {
    const w = windowOf(this) orelse return 0;
    const st = w.sidebar orelse return 0;
    return @intCast(st.items.len);
}

fn selectionDidChange(this: id, _: SEL, _: id) callconv(.c) void {
    const w = windowOf(this) orelse return;
    const st = w.sidebar orelse return;
    if (st.suppress) return;
    const row = st.table.msg(NSInteger, "selectedRow", .{});
    if (row < 0 or row >= st.items.len) return;
    const f = w.callbacks.sidebar_select orelse return;
    f(w.callbacks.ctx, .{ .index = @intCast(row) });
}

fn rowViewForRow(_: id, _: SEL, _: id, _: NSInteger) callconv(.c) ?id {
    const v = row_class.?.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{zero});
    return v.autorelease();
}

/// The selected row keeps the accent selection while the window is key, wherever the
/// keyboard focus is (System Settings; zpui's detail usually holds first responder).
fn rowIsEmphasized(this: id, _: SEL) callconv(.c) BOOL {
    const win = this.msg(?id, "window", .{}) orelse return NO;
    return win.msg(BOOL, "isKeyWindow", .{});
}

fn color(rgb: u32, alpha: CGFloat) id {
    const r: CGFloat = @floatFromInt((rgb >> 16) & 0xff);
    const g: CGFloat = @floatFromInt((rgb >> 8) & 0xff);
    const b: CGFloat = @floatFromInt(rgb & 0xff);
    return ak.class("NSColor").msg(id, "colorWithSRGBRed:green:blue:alpha:", .{ r / 255, g / 255, b / 255, alpha });
}

fn symbolImage(name: []const u8, point_size: CGFloat, weight: CGFloat) ?id {
    if (name.len == 0) return null;
    const ns_image = objc.getClass("NSImage") orelse return null;
    if (!responds(ns_image, "imageWithSystemSymbolName:accessibilityDescription:")) return null; // macOS 11+
    const base = ns_image.msg(?id, "imageWithSystemSymbolName:accessibilityDescription:", .{ ak.nsString(name), @as(?id, null) }) orelse return null;
    const cfg_class = objc.getClass("NSImageSymbolConfiguration") orelse return base;
    const cfg = cfg_class.msg(?id, "configurationWithPointSize:weight:scale:", .{ point_size, weight, @as(NSInteger, 2) }) orelse return base; // NSImageSymbolScaleMedium
    return base.msg(?id, "imageWithSymbolConfiguration:", .{cfg}) orelse base;
}

fn imageView(frame: NSRect, image: ?id) id {
    const v = ak.class("NSImageView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{frame});
    v.msg(void, "setImageScaling:", .{@as(NSUInteger, 0)}); // NSImageScaleProportionallyDown
    v.msg(void, "setImage:", .{image});
    return v.autorelease();
}

// NSLayoutAttribute raw values.
const attr_none: NSInteger = 0;
const attr_leading: NSInteger = 5;
const attr_trailing: NSInteger = 6;
const attr_width: NSInteger = 7;
const attr_height: NSInteger = 8;
const attr_center_y: NSInteger = 10;

/// `a.attr_a == b.attr_b + constant`, activated.
fn constrain(a: id, attr_a: NSInteger, b: ?id, attr_b: NSInteger, constant: CGFloat) void {
    const c = ak.class("NSLayoutConstraint").msg(id, "constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:", .{
        a, attr_a, @as(NSInteger, 0), b, attr_b, @as(CGFloat, if (b == null) 0 else 1), constant,
    });
    c.msg(void, "setActive:", .{YES});
}

fn viewForRow(this: id, _: SEL, table: id, _: ?id, row: NSInteger) callconv(.c) ?id {
    const w = windowOf(this) orelse return null;
    const st = w.sidebar orelse return null;
    if (row < 0 or row >= st.items.len) return null;
    const item = st.items[@intCast(row)];

    var h: CGFloat = table.msg(CGFloat, "rowHeight", .{});
    if (!(h > 0)) h = 28;
    const col_w: CGFloat = @max(ak.bounds(table).size.width, 120);
    const cell = ak.class("NSTableCellView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = col_w, .height = h } }});
    _ = cell.autorelease();

    // The icon: System Settings' white glyph on a colored rounded square, or the plain
    // (template) symbol the table tints. Laid out with constraints (NSTableCellView
    // repositions frame-based outlets in source lists).
    const icon: CGFloat = if (item.badge != null) @min(@max(h - 10, 18), 22) else @min(@max(h - 12, 16), 20);
    const icon_frame: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = icon, .height = icon } };
    var icon_view: ?id = null;
    var gap: CGFloat = 8;
    if (item.badge) |rgb| {
        const badge = ak.class("NSView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{icon_frame});
        _ = badge.autorelease();
        badge.msg(void, "setWantsLayer:", .{YES});
        if (badge.msg(?id, "layer", .{})) |l| {
            l.msg(void, "setBackgroundColor:", .{color(rgb, 1).msg(*anyopaque, "CGColor", .{})});
            l.msg(void, "setCornerRadius:", .{@as(CGFloat, @round(icon * 0.25))});
            if (responds(l, "setCornerCurve:")) l.msg(void, "setCornerCurve:", .{ak.nsString("continuous")});
        }
        const glyph_inset: CGFloat = @round(icon * 0.16);
        const glyph = imageView(.{ .origin = .{ .x = glyph_inset, .y = glyph_inset }, .size = .{ .width = icon - 2 * glyph_inset, .height = icon - 2 * glyph_inset } }, symbolImage(item.symbol, @round(icon * 0.5), 0.23)); // NSFontWeightMedium
        glyph.msg(void, "setContentTintColor:", .{ak.class("NSColor").msg(id, "whiteColor", .{})});
        glyph.msg(void, "setAutoresizingMask:", .{width_sizable | height_sizable});
        badge.msg(void, "addSubview:", .{glyph});
        icon_view = badge;
    } else if (symbolImage(item.symbol, @round(icon * 0.8), 0)) |img| {
        img.msg(void, "setTemplate:", .{YES});
        const iv = imageView(icon_frame, img);
        cell.msg(void, "setImageView:", .{iv});
        icon_view = iv;
        gap = 6;
    }

    const tf = ak.class("NSTextField").msg(id, "labelWithString:", .{ak.nsString(item.title)});
    tf.msg(void, "setLineBreakMode:", .{@as(NSUInteger, 4)}); // NSLineBreakByTruncatingTail
    tf.msg(void, "setContentCompressionResistancePriority:forOrientation:", .{ @as(f32, 250), @as(NSInteger, 0) });
    tf.msg(void, "setTranslatesAutoresizingMaskIntoConstraints:", .{NO});
    cell.msg(void, "addSubview:", .{tf});
    cell.msg(void, "setTextField:", .{tf});

    if (icon_view) |iv| {
        iv.msg(void, "setTranslatesAutoresizingMaskIntoConstraints:", .{NO});
        cell.msg(void, "addSubview:", .{iv});
        constrain(iv, attr_leading, cell, attr_leading, 2);
        constrain(iv, attr_center_y, cell, attr_center_y, 0);
        constrain(iv, attr_width, null, attr_none, icon);
        constrain(iv, attr_height, null, attr_none, icon);
        constrain(tf, attr_leading, iv, attr_trailing, gap);
    } else constrain(tf, attr_leading, cell, attr_leading, 2);
    constrain(tf, attr_center_y, cell, attr_center_y, 0);
    const trailing = ak.class("NSLayoutConstraint").msg(id, "constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:", .{
        tf, attr_trailing, @as(NSInteger, -1), cell, attr_trailing, @as(CGFloat, 1), @as(CGFloat, -4), // <=
    });
    trailing.msg(void, "setActive:", .{YES});
    return cell;
}
