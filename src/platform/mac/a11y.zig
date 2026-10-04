//! NSAccessibility bridge for zpui's accessibility tree (what `accesskit_macos` does for
//! zui, written directly against our Objective-C bindings).
//!
//! Each tree node (except the window root, which the content view stands for) is a
//! `ZPUIA11yElement` (an `NSAccessibilityElement` subclass) created lazily the first time
//! assistive technology reaches it, cached per `NodeId` and released when the node leaves
//! the tree. Elements hold only the bridge pointer and their node id; every attribute is
//! answered from the window's current tree, so an element always reflects the latest
//! frame. The content view (`ZPUIView`) answers `accessibilityChildren`,
//! `accessibilityFocusedUIElement` and `accessibilityHitTest:` for the root.
//!
//! Activation is lazy like AccessKit's: the first query on the view asks the core (on the
//! next main-queue turn) to start building trees; until the first tree arrives the view
//! has no children. After each frame `update` posts NSAccessibility notifications for the
//! change set: focus moves, value/title changes, selection and expansion changes, layout
//! changes when nodes come and go, and element destruction.
//!
//! Roles follow accesskit_macos's `ns_role` / `ns_subrole` mapping.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const dispatcher = @import("dispatcher.zig");
const platform = @import("../platform.zig");
const a11y = platform.a11y;
const window_mod = @import("window.zig");
const MacWindow = window_mod.MacWindow;

const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSRect = ak.NSRect;
const NSPoint = ak.NSPoint;
const NSUInteger = ak.NSUInteger;
const NSInteger = ak.NSInteger;
const NSRange = ak.NSRange;
const offsets = a11y.text_offsets;
const B = ak.enc_bool;

const bridge_ivar = "zpuiA11yBridge";
const node_ivar = "zpuiA11yNode";
const window_ivar = "zpuiWindow";

extern "c" fn NSAccessibilityPostNotification(element: id, notification: id) void;
extern "c" fn NSAccessibilityRoleDescription(role: id, subrole: ?id) ?id;

var element_class: ?*objc.Class = null;

/// Per-window bridge state (`MacWindow.a11y`).
pub const Bridge = struct {
    gpa: std.mem.Allocator,
    w: *MacWindow,
    /// The tree of the last frame (owned by the core; valid until the next update).
    tree: ?*const a11y.Tree = null,
    /// Live elements by node id (retained).
    elements: std.AutoHashMapUnmanaged(a11y.NodeId, id) = .empty,
    activation_requested: bool = false,
    /// Inside `update` (ignore re-entrant requests).
    updating: bool = false,

    fn node(br: *const Bridge, nid: a11y.NodeId) ?*const a11y.Node {
        const t = br.tree orelse return null;
        return t.get(nid);
    }

    /// The element for a node (created on first use). The root maps to the view.
    fn elementFor(br: *Bridge, nid: a11y.NodeId) ?id {
        if (nid == .root) return br.w.native_view;
        if (br.elements.get(nid)) |e| return e;
        const cls = element_class orelse return null;
        const e = cls.msg(?id, "alloc", .{}).?.msg(?id, "init", .{}) orelse return null;
        objc.setIvar(e, bridge_ivar, br);
        objc.setIvar(e, node_ivar, @ptrFromInt(@as(usize, @intCast(@intFromEnum(nid)))));
        br.elements.put(br.gpa, nid, e) catch {
            e.release();
            return null;
        };
        return e;
    }

    fn requestActivation(br: *Bridge) void {
        if (br.activation_requested) return;
        br.activation_requested = true;
        const Activate = struct {
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const view: id = @ptrCast(ctx.?);
                defer view.release();
                const w: *MacWindow = @ptrCast(@alignCast(objc.getIvar(view, window_ivar) orelse return));
                if (w.closed) return;
                if (w.callbacks.a11y_activation) |f| f(w.callbacks.ctx, true);
            }
        };
        dispatcher.onMain(br.w.native_view.retain(), &Activate.run);
    }

    fn perform(br: *Bridge, req: a11y.ActionRequest) bool {
        if (br.updating or br.w.closed) return false;
        const f = br.w.callbacks.a11y_action orelse return false;
        f(br.w.callbacks.ctx, req);
        return true;
    }

    /// Window-relative logical bounds → screen rect (AppKit, bottom-left origin).
    fn screenRect(br: *const Bridge, b: a11y.Bounds) NSRect {
        const view = br.w.native_view;
        const vb = ak.bounds(view);
        const local: NSRect = .{
            .origin = .{ .x = b.origin.x, .y = vb.size.height - @as(f64, b.origin.y) - b.size.height },
            .size = .{ .width = b.size.width, .height = b.size.height },
        };
        const in_window = ak.msgStruct(NSRect, view, "convertRect:toView:", .{ local, @as(?id, null) });
        return ak.msgStruct(NSRect, br.w.native_window, "convertRectToScreen:", .{in_window});
    }

    /// Screen point → window-relative logical point (top-left origin).
    fn fromScreen(br: *const Bridge, p: NSPoint) a11y.Point {
        const view = br.w.native_view;
        const in_window = br.w.native_window.msg(NSPoint, "convertPointFromScreen:", .{p});
        const local = view.msg(NSPoint, "convertPoint:fromView:", .{ in_window, @as(?id, null) });
        const vb = ak.bounds(view);
        return .{ .x = @floatCast(local.x), .y = @floatCast(vb.size.height - local.y) };
    }
};

/// Register `ZPUIA11yElement` (main thread, once).
pub fn registerClasses() void {
    if (element_class != null) return;
    const b = objc.ClassBuilder.init("NSAccessibilityElement", "ZPUIA11yElement") orelse {
        element_class = objc.getClass("ZPUIA11yElement");
        return;
    };
    _ = b.addPointerIvar(bridge_ivar);
    _ = b.addPointerIvar(node_ivar);
    _ = b.addMethod("accessibilityRole", &elRole, "@@:");
    _ = b.addMethod("accessibilitySubrole", &elSubrole, "@@:");
    _ = b.addMethod("accessibilityRoleDescription", &elRoleDescription, "@@:");
    _ = b.addMethod("accessibilityLabel", &elLabel, "@@:");
    _ = b.addMethod("accessibilityTitle", &elTitle, "@@:");
    _ = b.addMethod("accessibilityValue", &elValue, "@@:");
    _ = b.addMethod("accessibilityPlaceholderValue", &elPlaceholder, "@@:");
    _ = b.addMethod("accessibilityHelp", &elHelp, "@@:");
    _ = b.addMethod("accessibilityMinValue", &elMinValue, "@@:");
    _ = b.addMethod("accessibilityMaxValue", &elMaxValue, "@@:");
    _ = b.addMethod("accessibilityParent", &elParent, "@@:");
    _ = b.addMethod("accessibilityChildren", &elChildren, "@@:");
    _ = b.addMethod("accessibilityWindow", &elWindow, "@@:");
    _ = b.addMethod("accessibilityTopLevelUIElement", &elWindow, "@@:");
    _ = b.addMethod("accessibilityFrame", &elFrame, ak.enc_rect ++ "@:");
    _ = b.addMethod("isAccessibilityElement", &elIsElement, B ++ "@:");
    _ = b.addMethod("isAccessibilityFocused", &elIsFocused, B ++ "@:");
    _ = b.addMethod("isAccessibilityEnabled", &elIsEnabled, B ++ "@:");
    _ = b.addMethod("isAccessibilitySelected", &elIsSelected, B ++ "@:");
    _ = b.addMethod("isAccessibilityExpanded", &elIsExpanded, B ++ "@:");
    _ = b.addMethod("accessibilityPerformPress", &elPress, B ++ "@:");
    _ = b.addMethod("accessibilityPerformIncrement", &elIncrement, B ++ "@:");
    _ = b.addMethod("accessibilityPerformDecrement", &elDecrement, B ++ "@:");
    _ = b.addMethod("accessibilityPerformShowMenu", &elShowMenu, B ++ "@:");
    _ = b.addMethod("setAccessibilityFocused:", &elSetFocused, "v@:" ++ B);
    _ = b.addMethod("setAccessibilityValue:", &elSetValue, "v@:@");
    _ = b.addMethod("setAccessibilityExpanded:", &elSetExpanded, "v@:" ++ B);
    _ = b.addMethod("accessibilityHitTest:", &elHitTest, "@@:" ++ ak.enc_point);
    _ = b.addMethod("isAccessibilitySelectorAllowed:", &elSelectorAllowed, B ++ "@::");
    // Text ranges (NSAccessibility counts UTF-16 code units; the tree stores UTF-8 bytes).
    _ = b.addMethod("accessibilityNumberOfCharacters", &elNumberOfCharacters, "q@:");
    _ = b.addMethod("accessibilitySelectedText", &elSelectedText, "@@:");
    _ = b.addMethod("accessibilitySelectedTextRange", &elSelectedTextRange, ak.enc_range ++ "@:");
    _ = b.addMethod("accessibilitySelectedTextRanges", &elSelectedTextRanges, "@@:");
    _ = b.addMethod("setAccessibilitySelectedTextRange:", &elSetSelectedTextRange, "v@:" ++ ak.enc_range);
    _ = b.addMethod("accessibilityVisibleCharacterRange", &elVisibleCharacterRange, ak.enc_range ++ "@:");
    _ = b.addMethod("accessibilityInsertionPointLineNumber", &elInsertionPointLineNumber, "q@:");
    _ = b.addMethod("accessibilityStringForRange:", &elStringForRange, "@@:" ++ ak.enc_range);
    _ = b.addMethod("accessibilityAttributedStringForRange:", &elAttributedStringForRange, "@@:" ++ ak.enc_range);
    _ = b.addMethod("accessibilityLineForIndex:", &elLineForIndex, "q@:q");
    _ = b.addMethod("accessibilityRangeForLine:", &elRangeForLine, ak.enc_range ++ "@:q");
    _ = b.addMethod("accessibilityRangeForIndex:", &elRangeForIndex, ak.enc_range ++ "@:q");
    _ = b.addMethod("accessibilityStyleRangeForIndex:", &elRangeForIndex, ak.enc_range ++ "@:q");
    _ = b.addMethod("accessibilityRangeForPosition:", &elRangeForPosition, ak.enc_range ++ "@:" ++ ak.enc_point);
    _ = b.addMethod("accessibilityFrameForRange:", &elFrameForRange, ak.enc_rect ++ "@:" ++ ak.enc_range);
    _ = b.addMethod("accessibilityURL", &elURL, "@@:");
    element_class = b.register();
}

/// Accessibility overrides for the content view class (`ZPUIView`), which stands for the
/// tree's window node.
pub fn addViewMethods(b: objc.ClassBuilder) void {
    _ = b.addMethod("accessibilityChildren", &viewChildren, "@@:");
    _ = b.addMethod("accessibilityFocusedUIElement", &viewFocused, "@@:");
    _ = b.addMethod("accessibilityHitTest:", &viewHitTest, "@@:" ++ ak.enc_point);
    _ = b.addMethod("isAccessibilityElement", &viewIsElement, B ++ "@:");
    _ = b.addMethod("accessibilityRole", &viewRole, "@@:");
    _ = b.addMethod("accessibilityLabel", &viewLabel, "@@:");
}

/// `Window.VTable.a11yUpdate` for `MacWindow`.
pub fn update(w: *MacWindow, u: a11y.Update) void {
    if (w.closed) return;
    const br = bridgeOf(w) orelse return;
    br.tree = u.tree;
    br.updating = true;
    defer br.updating = false;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const ch = u.changes;
    var layout_changed = ch.full;
    for (ch.entries.items) |e| {
        if (e.what.removed) {
            layout_changed = true;
            if (br.elements.fetchRemove(e.id)) |kv| {
                post(kv.value, "AXUIElementDestroyed");
                objc.setIvar(kv.value, bridge_ivar, null);
                kv.value.release();
            }
            continue;
        }
        if (e.what.added or e.what.children) layout_changed = true;
        const el = br.elements.get(e.id) orelse continue; // never seen by AT: nothing to tell
        const n = br.node(e.id) orelse continue;
        if (e.what.name) post(el, "AXTitleChanged");
        if (e.what.value or e.what.numeric) post(el, "AXValueChanged");
        if (e.what.state) {
            if (!std.meta.eql(e.was_toggled, n.toggled)) post(el, "AXValueChanged");
            if (!std.meta.eql(e.was_selected, n.selected)) {
                if (u.tree.parentOf(u.tree.indexOf(e.id).?)) |p| if (br.elementFor(u.tree.at(p).id)) |pe| post(pe, "AXSelectedChildrenChanged");
            }
            if (!std.meta.eql(e.was_expanded, n.expanded)) {
                const expanded = n.expanded orelse false;
                post(el, if (n.role == .tree_item or n.role == .row) (if (expanded) "AXRowExpanded" else "AXRowCollapsed") else "AXExpandedChanged");
            }
        }
        if (e.what.text_selection) post(el, "AXSelectedTextChanged");
        if (e.what.bounds) post(el, "AXMoved");
    }
    if (layout_changed) post(w.native_view, "AXLayoutChanged");
    if (ch.focus_changed or ch.full) {
        if (br.elementFor(ch.new_focus)) |el| post(el, "AXFocusedUIElementChanged");
    }
}

/// Release every element (window teardown).
pub fn deinit(w: *MacWindow) void {
    const br = w.a11y orelse return;
    var it = br.elements.valueIterator();
    while (it.next()) |e| {
        objc.setIvar(e.*, bridge_ivar, null);
        e.*.release();
    }
    br.elements.deinit(br.gpa);
    w.a11y = null;
    br.gpa.destroy(br);
}

fn bridgeOf(w: *MacWindow) ?*Bridge {
    if (w.a11y) |b| return b;
    const br = w.gpa.create(Bridge) catch return null;
    br.* = .{ .gpa = w.gpa, .w = w };
    w.a11y = br;
    return br;
}

fn post(el: id, name: []const u8) void {
    NSAccessibilityPostNotification(el, ak.nsString(name));
}

// ---------------------------------------------------------------------------------------
// Role mapping (accesskit_macos `ns_role` / `ns_subrole`)
// ---------------------------------------------------------------------------------------

pub fn nsRole(r: a11y.Role) []const u8 {
    return switch (r) {
        .unknown, .generic_container => "AXUnknown",
        .window => "AXWindow",
        .group, .paragraph, .list_item, .tab_panel, .dialog, .alert_dialog, .alert, .status, .tooltip, .document, .article, .code, .navigation, .region, .pane => "AXGroup",
        .label => "AXStaticText",
        .heading => "AXHeading",
        .button, .default_button => "AXButton",
        .toggle_button => "AXCheckBox",
        .link => "AXLink",
        .check_box, .@"switch" => "AXCheckBox",
        .radio_button, .tab => "AXRadioButton",
        .text_input, .search_input, .password_input => "AXTextField",
        .multiline_text_input, .terminal => "AXTextArea",
        .combo_box => "AXComboBox",
        .spin_button => "AXIncrementor",
        .slider => "AXSlider",
        .progress_indicator => "AXProgressIndicator",
        .image => "AXImage",
        .list, .list_box => "AXList",
        .list_box_option => "AXStaticText",
        .menu => "AXMenu",
        .menu_bar => "AXMenuBar",
        .menu_item, .menu_item_check_box, .menu_item_radio => "AXMenuItem",
        .tab_list => "AXTabGroup",
        .tree => "AXOutline",
        .tree_item, .row => "AXRow",
        .table, .grid => "AXTable",
        .cell, .column_header, .row_header => "AXCell",
        .toolbar => "AXToolbar",
        .scroll_view => "AXScrollArea",
        .separator => "AXSplitter",
        .disclosure_triangle => "AXDisclosureTriangle",
    };
}

pub fn nsSubrole(r: a11y.Role) ?[]const u8 {
    return switch (r) {
        .@"switch" => "AXSwitch",
        .toggle_button => "AXToggle",
        .search_input => "AXSearchField",
        .password_input => "AXSecureTextField",
        .tab => "AXTabButton",
        .dialog => "AXDialog",
        .alert_dialog => "AXSystemDialog",
        .alert => "AXApplicationAlert",
        .status => "AXApplicationStatus",
        .document => "AXDocument",
        .article => "AXDocumentArticle",
        .navigation => "AXLandmarkNavigation",
        .region => "AXLandmarkRegion",
        .tree_item => "AXOutlineRow",
        .tooltip => "AXUserInterfaceTooltip",
        .code => "AXCodeStyleGroup",
        else => null,
    };
}

// ---------------------------------------------------------------------------------------
// ZPUIA11yElement methods
// ---------------------------------------------------------------------------------------

const Ctx = struct { br: *Bridge, id: a11y.NodeId, n: *const a11y.Node, tree: *const a11y.Tree };

fn ctxOf(this: id) ?Ctx {
    const br: *Bridge = @ptrCast(@alignCast(objc.getIvar(this, bridge_ivar) orelse return null));
    const raw = @intFromPtr(objc.getIvar(this, node_ivar) orelse return null);
    const nid: a11y.NodeId = @enumFromInt(@as(u64, @intCast(raw)));
    const tree = br.tree orelse return null;
    const n = tree.get(nid) orelse return null;
    return .{ .br = br, .id = nid, .n = n, .tree = tree };
}

fn str(s: ?[]const u8) ?id {
    return if (s) |v| ak.nsString(v) else null;
}

fn number(v: f64) id {
    return ak.class("NSNumber").msg(id, "numberWithDouble:", .{v});
}

fn integer(v: isize) id {
    return ak.class("NSNumber").msg(id, "numberWithInteger:", .{v});
}

fn elRole(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return ak.nsString("AXUnknown");
    return ak.nsString(nsRole(c.n.role));
}

fn elSubrole(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return str(nsSubrole(c.n.role));
}

fn elRoleDescription(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return NSAccessibilityRoleDescription(ak.nsString(nsRole(c.n.role)), str(nsSubrole(c.n.role)));
}

/// Static text exposes its text as the value; everything else as the label.
fn elLabel(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    if (c.n.role == .label or (c.n.role == .list_box_option and !c.n.label.present)) return null;
    return str(c.tree.name(c.n));
}

fn elTitle(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    // Buttons, menu items, tabs and links read their title (VoiceOver prefers it).
    return switch (c.n.role) {
        .button, .default_button, .menu_item, .menu_item_check_box, .menu_item_radio, .tab, .radio_button, .check_box, .@"switch", .toggle_button, .link, .disclosure_triangle => str(c.tree.name(c.n)),
        else => null,
    };
}

fn elValue(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    const n = c.n;
    if (n.toggled) |t| return integer(switch (t) {
        .off => 0,
        .on => 1,
        .mixed => 2,
    });
    if (n.role == .tab or n.role == .radio_button) if (n.selected) |s| return integer(@intFromBool(s));
    if (n.numeric_value) |v| return number(v);
    if (c.tree.str(n.value)) |v| return ak.nsString(v);
    if (n.role == .label or n.role == .list_box_option) return str(c.tree.name(n));
    if (n.role.isTextInput()) return ak.nsString("");
    return null;
}

fn elPlaceholder(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return str(c.tree.str(c.n.placeholder));
}

fn elHelp(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return str(c.tree.str(c.n.description));
}

fn elMinValue(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return if (c.n.min_numeric_value) |v| number(v) else null;
}

fn elMaxValue(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return if (c.n.max_numeric_value) |v| number(v) else null;
}

fn elParent(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    const ix = c.tree.indexOf(c.id) orelse return null;
    const p = c.tree.parentOf(ix) orelse return c.br.w.native_view;
    return c.br.elementFor(c.tree.at(p).id);
}

fn childrenArray(br: *Bridge, tree: *const a11y.Tree, ix: u32) id {
    const kids = tree.children(ix);
    const arr = ak.class("NSMutableArray").msg(id, "arrayWithCapacity:", .{@as(NSUInteger, kids.len)});
    for (kids) |k| if (br.elementFor(tree.at(k).id)) |e| arr.msg(void, "addObject:", .{e});
    return arr;
}

fn emptyArray() id {
    return ak.class("NSArray").msg(id, "array", .{});
}

fn elChildren(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return emptyArray();
    return childrenArray(c.br, c.tree, c.tree.indexOf(c.id).?);
}

fn elWindow(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    return c.br.w.native_window;
}

fn elFrame(this: id, _: SEL) callconv(.c) NSRect {
    const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const c = ctxOf(this) orelse return zero;
    return c.br.screenRect(c.n.bounds);
}

fn elIsElement(this: id, _: SEL) callconv(.c) BOOL {
    const c = ctxOf(this) orelse return NO;
    return objc.toBOOL(c.n.role != .generic_container and c.n.role != .unknown);
}

fn elIsFocused(this: id, _: SEL) callconv(.c) BOOL {
    const c = ctxOf(this) orelse return NO;
    return objc.toBOOL(c.tree.focusId() == c.id);
}

fn elIsEnabled(this: id, _: SEL) callconv(.c) BOOL {
    const c = ctxOf(this) orelse return NO;
    return objc.toBOOL(!c.n.disabled);
}

fn elIsSelected(this: id, _: SEL) callconv(.c) BOOL {
    const c = ctxOf(this) orelse return NO;
    return objc.toBOOL(c.n.selected orelse false);
}

fn elIsExpanded(this: id, _: SEL) callconv(.c) BOOL {
    const c = ctxOf(this) orelse return NO;
    return objc.toBOOL(c.n.expanded orelse false);
}

fn act(this: id, action: a11y.Action) BOOL {
    const c = ctxOf(this) orelse return NO;
    return objc.toBOOL(c.br.perform(.{ .target = c.id, .action = action }));
}

fn elPress(this: id, _: SEL) callconv(.c) BOOL {
    return act(this, .click);
}

fn elIncrement(this: id, _: SEL) callconv(.c) BOOL {
    return act(this, .increment);
}

fn elDecrement(this: id, _: SEL) callconv(.c) BOOL {
    return act(this, .decrement);
}

fn elShowMenu(this: id, _: SEL) callconv(.c) BOOL {
    return act(this, .show_context_menu);
}

fn elSetFocused(this: id, _: SEL, focused: BOOL) callconv(.c) void {
    _ = act(this, if (objc.fromBOOL(focused)) .focus else .blur);
}

fn elSetExpanded(this: id, _: SEL, expanded: BOOL) callconv(.c) void {
    _ = act(this, if (objc.fromBOOL(expanded)) .expand else .collapse);
}

fn elSetValue(this: id, _: SEL, value: ?id) callconv(.c) void {
    const c = ctxOf(this) orelse return;
    const v = value orelse return;
    if (objc.isKindOf(v, ak.class("NSString"))) {
        _ = c.br.perform(.{ .target = c.id, .action = .set_value, .value = ak.stringBytes(v) });
    } else if (objc.isKindOf(v, ak.class("NSNumber"))) {
        _ = c.br.perform(.{ .target = c.id, .action = .set_value, .numeric = v.msg(f64, "doubleValue", .{}) });
    }
}

fn elHitTest(this: id, _: SEL, p: NSPoint) callconv(.c) ?id {
    const c = ctxOf(this) orelse return this;
    return hitTest(c.br, p) orelse this;
}

/// Expose only what a node supports (accesskit_macos `isAccessibilitySelectorAllowed:`).
fn elSelectorAllowed(this: id, _: SEL, selector: SEL) callconv(.c) BOOL {
    const c = ctxOf(this) orelse return NO;
    const n = c.n;
    const Check = struct {
        fn is(s: SEL, comptime name: [:0]const u8) bool {
            return s == objc.cachedSel(name);
        }
    };
    if (Check.is(selector, "accessibilityPerformPress")) return objc.toBOOL(n.actions.contains(.click));
    if (Check.is(selector, "accessibilityPerformIncrement")) return objc.toBOOL(n.actions.contains(.increment));
    if (Check.is(selector, "accessibilityPerformDecrement")) return objc.toBOOL(n.actions.contains(.decrement));
    if (Check.is(selector, "accessibilityPerformShowMenu")) return objc.toBOOL(n.actions.contains(.show_context_menu));
    if (Check.is(selector, "setAccessibilityFocused:")) return objc.toBOOL(n.isFocusable());
    if (Check.is(selector, "setAccessibilityValue:")) return objc.toBOOL(n.actions.contains(.set_value) and !n.read_only);
    if (Check.is(selector, "setAccessibilityExpanded:")) return objc.toBOOL(n.actions.contains(.expand) or n.actions.contains(.collapse));
    if (Check.is(selector, "accessibilityPlaceholderValue")) return objc.toBOOL(n.placeholder.present);
    if (Check.is(selector, "isAccessibilityExpanded")) return objc.toBOOL(n.expanded != null);
    if (Check.is(selector, "isAccessibilitySelected")) return objc.toBOOL(n.selected != null);
    if (Check.is(selector, "accessibilityMinValue") or Check.is(selector, "accessibilityMaxValue")) return objc.toBOOL(n.role.isRange());
    if (Check.is(selector, "setAccessibilitySelectedTextRange:")) return objc.toBOOL(n.actions.contains(.set_text_selection));
    if (Check.is(selector, "accessibilityURL")) return objc.toBOOL(n.role == .link and n.url.present);
    inline for (text_selectors) |name| if (Check.is(selector, name)) return objc.toBOOL(hasText(n));
    return YES;
}

fn hitTest(br: *Bridge, p: NSPoint) ?id {
    const tree = br.tree orelse return null;
    const ix = tree.hitTest(br.fromScreen(p)) orelse return null;
    var cur = ix;
    // Skip ignored nodes up to an exposed ancestor.
    while (cur != 0) {
        const n = tree.at(cur);
        if (n.role != .generic_container and n.role != .unknown) return br.elementFor(n.id);
        cur = tree.parentOf(cur) orelse 0;
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// ZPUIView (content view = window node)
// ---------------------------------------------------------------------------------------

fn viewBridge(this: id) ?*Bridge {
    const w: *MacWindow = @ptrCast(@alignCast(objc.getIvar(this, window_ivar) orelse return null));
    if (w.closed) return null;
    const br = bridgeOf(w) orelse return null;
    br.requestActivation();
    return br;
}

fn viewChildren(this: id, _: SEL) callconv(.c) ?id {
    const br = viewBridge(this) orelse return emptyArray();
    const tree = br.tree orelse return emptyArray();
    if (tree.len() == 0) return emptyArray();
    return childrenArray(br, tree, 0);
}

fn viewFocused(this: id, _: SEL) callconv(.c) ?id {
    const br = viewBridge(this) orelse return this;
    const tree = br.tree orelse return this;
    return br.elementFor(tree.focusId()) orelse this;
}

fn viewHitTest(this: id, _: SEL, p: NSPoint) callconv(.c) ?id {
    const br = viewBridge(this) orelse return this;
    return hitTest(br, p) orelse this;
}

fn viewIsElement(_: id, _: SEL) callconv(.c) BOOL {
    return YES;
}

fn viewRole(_: id, _: SEL) callconv(.c) ?id {
    return ak.nsString("AXGroup");
}

fn viewLabel(this: id, _: SEL) callconv(.c) ?id {
    const br = viewBridge(this) orelse return null;
    const tree = br.tree orelse return null;
    const root = tree.root() orelse return null;
    return str(tree.str(root.label));
}

// ---------------------------------------------------------------------------------------
// Text ranges (accesskit_macos text support): text fields expose their value with the
// caret / selection from the node's `text_selection`; static text its string.
// ---------------------------------------------------------------------------------------

const text_selectors = [_][:0]const u8{
    "accessibilityNumberOfCharacters",
    "accessibilitySelectedText",
    "accessibilitySelectedTextRange",
    "accessibilitySelectedTextRanges",
    "accessibilityVisibleCharacterRange",
    "accessibilityInsertionPointLineNumber",
    "accessibilityStringForRange:",
    "accessibilityAttributedStringForRange:",
    "accessibilityLineForIndex:",
    "accessibilityRangeForLine:",
    "accessibilityRangeForIndex:",
    "accessibilityStyleRangeForIndex:",
    "accessibilityRangeForPosition:",
    "accessibilityFrameForRange:",
};

fn hasText(n: *const a11y.Node) bool {
    return n.role.isTextInput() or n.role == .label;
}

fn textOf(c: Ctx) []const u8 {
    if (c.n.role.isTextInput()) return c.tree.str(c.n.value) orelse "";
    return c.tree.name(c.n) orelse "";
}

fn nsRange(loc: usize, len: usize) NSRange {
    return .{ .location = loc, .length = len };
}

/// UTF-16 range → byte range `[start, end)` of `text` (clamped).
fn byteRange(text: []const u8, r: NSRange) [2]usize {
    const s = offsets.utf16ToByte(text, r.location);
    const e = offsets.utf16ToByte(text, r.location +| r.length);
    return .{ s, @max(s, e) };
}

/// The selection as a UTF-16 range (the caret at the end of the text when the node
/// publishes none).
fn selectedRange(c: Ctx) NSRange {
    const text = textOf(c);
    const sel = c.n.text_selection orelse return nsRange(offsets.utf16Len(text), 0);
    const s = offsets.byteToUtf16(text, sel.start());
    const e = offsets.byteToUtf16(text, sel.end());
    return nsRange(s, e - s);
}

fn elNumberOfCharacters(this: id, _: SEL) callconv(.c) NSInteger {
    const c = ctxOf(this) orelse return 0;
    return @intCast(offsets.utf16Len(textOf(c)));
}

fn elSelectedText(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    const text = textOf(c);
    const sel = c.n.text_selection orelse return ak.nsString("");
    return ak.nsString(text[@min(sel.start(), text.len)..@min(sel.end(), text.len)]);
}

fn elSelectedTextRange(this: id, _: SEL) callconv(.c) NSRange {
    const c = ctxOf(this) orelse return nsRange(0, 0);
    return selectedRange(c);
}

fn elSelectedTextRanges(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    const v = ak.class("NSValue").msg(id, "valueWithRange:", .{selectedRange(c)});
    return ak.class("NSArray").msg(id, "arrayWithObject:", .{v});
}

fn elSetSelectedTextRange(this: id, _: SEL, r: NSRange) callconv(.c) void {
    const c = ctxOf(this) orelse return;
    const br = byteRange(textOf(c), r);
    _ = c.br.perform(.{ .target = c.id, .action = .set_text_selection, .selection = .{ .anchor = @intCast(br[0]), .focus = @intCast(br[1]) } });
}

fn elVisibleCharacterRange(this: id, _: SEL) callconv(.c) NSRange {
    const c = ctxOf(this) orelse return nsRange(0, 0);
    return nsRange(0, offsets.utf16Len(textOf(c)));
}

fn elInsertionPointLineNumber(this: id, _: SEL) callconv(.c) NSInteger {
    const c = ctxOf(this) orelse return 0;
    const text = textOf(c);
    const caret = if (c.n.text_selection) |s| s.focus else text.len;
    return @intCast(offsets.lineOf(text, caret));
}

fn elStringForRange(this: id, _: SEL, r: NSRange) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    const text = textOf(c);
    const br = byteRange(text, r);
    return ak.nsString(text[br[0]..br[1]]);
}

fn elAttributedStringForRange(this: id, sel: SEL, r: NSRange) callconv(.c) ?id {
    const s = elStringForRange(this, sel, r) orelse return null;
    return ak.class("NSAttributedString").msg(id, "alloc", .{}).msg(id, "initWithString:", .{s}).autorelease();
}

fn elLineForIndex(this: id, _: SEL, index: NSInteger) callconv(.c) NSInteger {
    const c = ctxOf(this) orelse return 0;
    const text = textOf(c);
    return @intCast(offsets.lineOf(text, offsets.utf16ToByte(text, @intCast(@max(0, index)))));
}

fn elRangeForLine(this: id, _: SEL, line: NSInteger) callconv(.c) NSRange {
    const c = ctxOf(this) orelse return nsRange(ak.NSNotFound, 0);
    const text = textOf(c);
    const lr = offsets.lineRange(text, @intCast(@max(0, line))) orelse return nsRange(ak.NSNotFound, 0);
    const s = offsets.byteToUtf16(text, lr[0]);
    return nsRange(s, offsets.byteToUtf16(text, lr[1]) - s);
}

/// The composed character at a UTF-16 index (a surrogate pair is one range).
fn elRangeForIndex(this: id, _: SEL, index: NSInteger) callconv(.c) NSRange {
    const c = ctxOf(this) orelse return nsRange(ak.NSNotFound, 0);
    const text = textOf(c);
    const b0 = offsets.utf16ToByte(text, @intCast(@max(0, index)));
    if (b0 >= text.len) return nsRange(offsets.utf16Len(text), 0);
    const b1 = offsets.charToByte(text, offsets.byteToChar(text, b0) + 1);
    const s = offsets.byteToUtf16(text, b0);
    return nsRange(s, offsets.byteToUtf16(text, b1) - s);
}

/// Without glyph geometry in the tree, a point maps to the line it falls on (by the
/// node's height / line count) — the line's whole range.
fn elRangeForPosition(this: id, sel: SEL, p: NSPoint) callconv(.c) NSRange {
    const c = ctxOf(this) orelse return nsRange(ak.NSNotFound, 0);
    const text = textOf(c);
    const lines = offsets.lineOf(text, text.len) + 1;
    const local = c.br.fromScreen(p);
    const b = c.n.bounds;
    if (b.size.height <= 0) return nsRange(0, 0);
    const frac = (local.y - b.origin.y) / b.size.height;
    const line: NSInteger = @intFromFloat(std.math.clamp(@floor(frac * @as(f32, @floatFromInt(lines))), 0, @as(f32, @floatFromInt(lines - 1))));
    return elRangeForLine(this, sel, line);
}

fn elFrameForRange(this: id, _: SEL, _: NSRange) callconv(.c) NSRect {
    const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const c = ctxOf(this) orelse return zero;
    return c.br.screenRect(c.n.bounds);
}

fn elURL(this: id, _: SEL) callconv(.c) ?id {
    const c = ctxOf(this) orelse return null;
    const u = c.tree.str(c.n.url) orelse return null;
    return ak.class("NSURL").msg(?id, "URLWithString:", .{ak.nsString(u)});
}
