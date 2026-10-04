//! IME / text input bridge (gpui `EntityInputHandler`, `ElementInputHandler`,
//! `PlatformInputHandler`).
//!
//! A text-editing view implements some of these methods (ranges are UTF-16 offsets, as on
//! macOS; only `replaceTextInRange` is required):
//!
//! ```zig
//! pub fn selectedTextRange(self: *V, window: *Window, cx: *Context(V)) ?Selection
//! pub fn markedTextRange(self: *V, window: *Window, cx: *Context(V)) ?Range
//! pub fn textForRange(self: *V, range: Range, out: *std.ArrayList(u8), window: *Window, cx: *Context(V)) ?Range
//! pub fn replaceTextInRange(self: *V, range: ?Range, text: []const u8, window: *Window, cx: *Context(V)) void
//! pub fn replaceAndMarkTextInRange(self: *V, range: ?Range, text: []const u8, new_selected: ?Range, window: *Window, cx: *Context(V)) void
//! pub fn unmarkText(self: *V, window: *Window, cx: *Context(V)) void
//! pub fn boundsForRange(self: *V, range: Range, element_bounds: Bounds, window: *Window, cx: *Context(V)) ?Bounds
//! pub fn acceptsTextInput(self: *V, window: *Window, cx: *Context(V)) bool
//! ```
//!
//! Its element calls `window.handleInput(focus_handle, .init(view_entity, bounds))` during
//! paint; the last handler registered by a focused element is given to the platform, whose
//! IME callbacks re-enter the App through the window.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const App = @import("../app/app.zig").App;
const entity_mod = @import("../app/entity.zig");
const EntityId = entity_mod.EntityId;
const Window = @import("window.zig").Window;

pub const Range = platform.InputHandler.Range;
pub const Selection = struct { range: Range, reversed: bool = false };
const Bounds = geometry.Bounds(geometry.Pixels);

pub const ElementInputHandler = struct {
    entity_id: EntityId,
    element_bounds: Bounds,
    vtable: *const VTable,

    pub const VTable = struct {
        selected_text_range: *const fn (EntityId, *Window, *App) ?Selection,
        marked_text_range: *const fn (EntityId, *Window, *App) ?Range,
        text_for_range: *const fn (EntityId, Range, *std.ArrayList(u8), *Window, *App) ?Range,
        replace_text_in_range: *const fn (EntityId, ?Range, []const u8, *Window, *App) void,
        replace_and_mark_text_in_range: *const fn (EntityId, ?Range, []const u8, ?Range, *Window, *App) void,
        unmark_text: *const fn (EntityId, *Window, *App) void,
        bounds_for_range: *const fn (EntityId, Range, Bounds, *Window, *App) ?Bounds,
        accepts_text_input: *const fn (EntityId, *Window, *App) bool,
    };

    /// Adapt view entity `view` (an `Entity(V)`) whose element occupies `element_bounds`.
    pub fn init(view: anytype, element_bounds: Bounds) ElementInputHandler {
        const V = @TypeOf(view).Type;
        return .{ .entity_id = view.id, .element_bounds = element_bounds, .vtable = vtableFor(V) };
    }

    pub fn replaceTextInRange(self: ElementInputHandler, window: *Window, range: ?Range, text: []const u8) void {
        self.vtable.replace_text_in_range(self.entity_id, range, text, window, window.app);
    }

    pub fn acceptsTextInput(self: ElementInputHandler, window: *Window) bool {
        return self.vtable.accepts_text_input(self.entity_id, window, window.app);
    }
};

fn vtableFor(comptime V: type) *const ElementInputHandler.VTable {
    const W = entity_mod.WeakEntity(V);
    return &struct {
        const vt: ElementInputHandler.VTable = .{
            .selected_text_range = selected,
            .marked_text_range = marked,
            .text_for_range = textFor,
            .replace_text_in_range = replace,
            .replace_and_mark_text_in_range = replaceMark,
            .unmark_text = unmark,
            .bounds_for_range = boundsFor,
            .accepts_text_input = accepts,
        };
        fn selected(id: EntityId, w: *Window, a: *App) ?Selection {
            if (comptime @hasDecl(V, "selectedTextRange")) {
                return (W{ .id = id }).update(a, V.selectedTextRange, .{w}) orelse null;
            } else return null;
        }
        fn marked(id: EntityId, w: *Window, a: *App) ?Range {
            if (comptime @hasDecl(V, "markedTextRange")) {
                return (W{ .id = id }).update(a, V.markedTextRange, .{w}) orelse null;
            } else return null;
        }
        fn textFor(id: EntityId, r: Range, out: *std.ArrayList(u8), w: *Window, a: *App) ?Range {
            if (comptime @hasDecl(V, "textForRange")) {
                return (W{ .id = id }).update(a, V.textForRange, .{ r, out, w }) orelse null;
            } else return null;
        }
        fn replace(id: EntityId, r: ?Range, text: []const u8, w: *Window, a: *App) void {
            _ = (W{ .id = id }).update(a, V.replaceTextInRange, .{ r, text, w });
        }
        fn replaceMark(id: EntityId, r: ?Range, text: []const u8, sel: ?Range, w: *Window, a: *App) void {
            if (comptime @hasDecl(V, "replaceAndMarkTextInRange")) {
                _ = (W{ .id = id }).update(a, V.replaceAndMarkTextInRange, .{ r, text, sel, w });
            } else replace(id, r, text, w, a);
        }
        fn unmark(id: EntityId, w: *Window, a: *App) void {
            if (comptime @hasDecl(V, "unmarkText")) _ = (W{ .id = id }).update(a, V.unmarkText, .{w});
        }
        fn boundsFor(id: EntityId, r: Range, eb: Bounds, w: *Window, a: *App) ?Bounds {
            if (comptime @hasDecl(V, "boundsForRange")) {
                return (W{ .id = id }).update(a, V.boundsForRange, .{ r, eb, w }) orelse null;
            } else return null;
        }
        fn accepts(id: EntityId, w: *Window, a: *App) bool {
            if (comptime @hasDecl(V, "acceptsTextInput")) {
                return (W{ .id = id }).update(a, V.acceptsTextInput, .{w}) orelse false;
            } else return true;
        }
    }.vt;
}

/// The `platform.InputHandler` a window installs on its platform window. It forwards to the
/// window's current element input handler inside an App update.
pub fn platformHandler(window: *Window) platform.InputHandler {
    return .{ .ptr = window, .vtable = &bridge };
}

const SelRet = @typeInfo(@typeInfo(@FieldType(platform.InputHandler.VTable, "selectedTextRange")).pointer.child).@"fn".return_type.?;

const bridge: platform.InputHandler.VTable = .{
    .selectedTextRange = bSelected,
    .markedTextRange = bMarked,
    .textForRange = bTextFor,
    .replaceTextInRange = bReplace,
    .replaceAndMarkTextInRange = bReplaceMark,
    .unmarkText = bUnmark,
    .boundsForRange = bBounds,
};

fn win(p: *anyopaque) *Window {
    return @ptrCast(@alignCast(p));
}

fn bSelected(p: *anyopaque) SelRet {
    const w = win(p);
    const h = w.input_handler orelse return null;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    const s = h.vtable.selected_text_range(h.entity_id, w, w.app) orelse return null;
    return .{ .range = s.range, .reversed = s.reversed };
}
fn bMarked(p: *anyopaque) ?Range {
    const w = win(p);
    const h = w.input_handler orelse return null;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    return h.vtable.marked_text_range(h.entity_id, w, w.app);
}
fn bTextFor(p: *anyopaque, r: Range, out: *std.ArrayList(u8), gpa: std.mem.Allocator) ?Range {
    _ = gpa; // views append with the App allocator, which the platform passes here too
    const w = win(p);
    const h = w.input_handler orelse return null;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    return h.vtable.text_for_range(h.entity_id, r, out, w, w.app);
}
fn bReplace(p: *anyopaque, r: ?Range, text: []const u8) void {
    const w = win(p);
    const h = w.input_handler orelse return;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    h.vtable.replace_text_in_range(h.entity_id, r, text, w, w.app);
}
fn bReplaceMark(p: *anyopaque, r: ?Range, text: []const u8, sel: ?Range) void {
    const w = win(p);
    const h = w.input_handler orelse return;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    h.vtable.replace_and_mark_text_in_range(h.entity_id, r, text, sel, w, w.app);
}
fn bUnmark(p: *anyopaque) void {
    const w = win(p);
    const h = w.input_handler orelse return;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    h.vtable.unmark_text(h.entity_id, w, w.app);
}
fn bBounds(p: *anyopaque, r: Range) ?Bounds {
    const w = win(p);
    const h = w.input_handler orelse return null;
    w.app.startUpdate();
    defer w.app.finishUpdate();
    return h.vtable.bounds_for_range(h.entity_id, r, h.element_bounds, w, w.app);
}
