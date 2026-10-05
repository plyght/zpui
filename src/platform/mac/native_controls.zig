//! macOS native form controls (`zpui.nativeSwitch` & co., platform.NativeControlState):
//! NSSwitch, NSButton (checkbox), NSSlider, NSSegmentedControl, NSPopUpButton and
//! NSStepper, hosted as native child views (native_views.zig: clipped to the visible
//! region, hidden when not painted, under the overlay plane or floating above it).
//!
//! * One `ZPUINativeControlTarget` per window is every control's target; its action
//!   reads the sender's new value and calls `WindowCallbacks.native_control` (main
//!   thread, from AppKit's event handling / tracking loop).
//! * Controls refuse first responder, so clicking one never takes the keyboard from
//!   zpui (its shortcuts keep working); VoiceOver acts on them through accessibility.
//! * Programmatic updates (`update`) never send actions.
//! * `measure` reports the frame size for the control's intrinsic content size plus its
//!   alignment-rect insets (the layout box is the view's frame).
//! * `dark` pins `NSAppearance` (DarkAqua / Aqua) like the Liquid Glass views.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const platform = @import("../platform.zig");
const window_mod = @import("window.zig");
const native_views = @import("native_views.zig");

const MacWindow = window_mod.MacWindow;
const id = objc.id;
const SEL = objc.SEL;
const YES = objc.YES;
const NO = objc.NO;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;
const CGFloat = ak.CGFloat;
const NSRect = ak.NSRect;

const window_ivar = "zpuiWindow";
const action_selector = "zpuiControlAction:";

var target_class: ?*objc.Class = null;

fn targetClass() *objc.Class {
    if (target_class) |c| return c;
    const c = blk: {
        const b = objc.ClassBuilder.init("NSObject", "ZPUINativeControlTarget") orelse break :blk objc.getClass("ZPUINativeControlTarget").?;
        _ = b.addPointerIvar(window_ivar);
        _ = b.addMethod(action_selector, &controlAction, "v@:@");
        break :blk b.register();
    };
    target_class = c;
    return c;
}

/// The window's action target (NSControl targets are weak: the host keeps it).
fn target(w: *MacWindow) id {
    if (w.natives.control_target) |t| return t;
    const t = targetClass().msg(id, "new", .{});
    objc.setIvar(t, window_ivar, w);
    w.natives.control_target = t;
    return t;
}

fn controlAction(this: id, _: SEL, sender: id) callconv(.c) void {
    const w: *MacWindow = @ptrCast(@alignCast(objc.getIvar(this, window_ivar) orelse return));
    if (w.closed) return;
    const ident, const kind = native_views.controlOf(w, sender) orelse return;
    const event: platform.NativeControlEvent = switch (kind) {
        .switch_, .checkbox => .{ .kind = kind, .on = sender.msg(NSInteger, "state", .{}) == 1 },
        .slider, .stepper => .{ .kind = kind, .value = sender.msg(f64, "doubleValue", .{}) },
        .segmented, .popup => blk: {
            const ix = if (kind == .segmented) sender.msg(NSInteger, "selectedSegment", .{}) else sender.msg(NSInteger, "indexOfSelectedItem", .{});
            if (ix < 0) return;
            break :blk .{ .kind = kind, .index = @intCast(ix) };
        },
    };
    const f = w.callbacks.native_control orelse return;
    f(w.callbacks.ctx, ident, event);
}

fn alloc(comptime name: [:0]const u8) ?id {
    const cls = objc.getClass(name) orelse return null;
    return cls.msg(id, "alloc", .{});
}

const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

/// A new (+1) control of `kind`, or null when AppKit lacks it (NSSwitch: 10.15+).
fn create(kind: platform.NativeControlKind) ?id {
    switch (kind) {
        .switch_ => return (alloc("NSSwitch") orelse return null).msg(id, "initWithFrame:", .{zero}),
        .checkbox => {
            const b = (alloc("NSButton") orelse return null).msg(id, "initWithFrame:", .{zero});
            b.msg(void, "setButtonType:", .{@as(NSUInteger, 3)}); // NSButtonTypeSwitch
            return b;
        },
        .slider => {
            const s = (alloc("NSSlider") orelse return null).msg(id, "initWithFrame:", .{zero});
            s.msg(void, "setContinuous:", .{YES});
            return s;
        },
        .segmented => {
            const s = (alloc("NSSegmentedControl") orelse return null).msg(id, "initWithFrame:", .{zero});
            s.msg(void, "setTrackingMode:", .{@as(NSUInteger, 0)}); // NSSegmentSwitchTrackingSelectOne
            return s;
        },
        .popup => return (alloc("NSPopUpButton") orelse return null).msg(id, "initWithFrame:pullsDown:", .{ zero, NO }),
        .stepper => {
            const s = (alloc("NSStepper") orelse return null).msg(id, "initWithFrame:", .{zero});
            s.msg(void, "setValueWraps:", .{NO});
            s.msg(void, "setAutorepeat:", .{YES});
            return s;
        },
    }
}

fn str(s: []const u8) id {
    return ak.nsString(s);
}

/// Push `state` into control `v` (no actions are sent for programmatic changes).
fn apply(v: id, state: platform.NativeControlState) void {
    const size: NSUInteger = @intFromEnum(state.size);
    v.msg(void, "setControlSize:", .{size});
    if (state.dark) |dark| {
        const name = objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
        v.msg(void, "setAppearance:", .{ak.class("NSAppearance").msg(?id, "appearanceNamed:", .{name})});
    } else v.msg(void, "setAppearance:", .{@as(?id, null)});
    switch (state.kind) {
        .checkbox, .segmented, .popup => {
            const NSFont = ak.class("NSFont");
            const pt = NSFont.msg(CGFloat, "systemFontSizeForControlSize:", .{size});
            v.msg(void, "setFont:", .{NSFont.msg(id, "systemFontOfSize:", .{pt})});
        },
        else => {},
    }
    const on: NSInteger = if (state.on) 1 else 0;
    switch (state.kind) {
        .switch_ => v.msg(void, "setState:", .{on}),
        .checkbox => {
            v.msg(void, "setTitle:", .{str(state.title)});
            v.msg(void, "setState:", .{on});
        },
        .slider => {
            v.msg(void, "setMinValue:", .{state.min});
            v.msg(void, "setMaxValue:", .{state.max});
            const ticks: NSInteger = if (state.step > 0 and state.max > state.min)
                @intFromFloat(@min(@round((state.max - state.min) / state.step) + 1, 200))
            else
                0;
            v.msg(void, "setNumberOfTickMarks:", .{ticks});
            v.msg(void, "setAllowsTickMarkValuesOnly:", .{objc.toBOOL(ticks > 0)});
            v.msg(void, "setDoubleValue:", .{state.value});
        },
        .stepper => {
            v.msg(void, "setMinValue:", .{state.min});
            v.msg(void, "setMaxValue:", .{state.max});
            v.msg(void, "setIncrement:", .{if (state.step > 0) state.step else 1});
            v.msg(void, "setDoubleValue:", .{state.value});
        },
        .segmented => {
            v.msg(void, "setSegmentCount:", .{@as(NSInteger, @intCast(state.items.len))});
            for (state.items, 0..) |item, i| v.msg(void, "setLabel:forSegment:", .{ str(item), @as(NSInteger, @intCast(i)) });
            const sel: NSInteger = if (state.selected) |s| @intCast(s) else -1;
            v.msg(void, "setSelectedSegment:", .{sel});
        },
        .popup => {
            v.msg(void, "removeAllItems", .{});
            // `addItemWithTitle:` drops duplicate titles; the menu keeps every row.
            const menu = v.msg(id, "menu", .{});
            for (state.items) |item| _ = menu.msg(?id, "addItemWithTitle:action:keyEquivalent:", .{ str(item), @as(?SEL, null), str("") });
            const sel: NSInteger = if (state.selected) |s| @intCast(s) else -1;
            v.msg(void, "selectItemAtIndex:", .{sel});
        },
    }
    v.msg(void, "setEnabled:", .{objc.toBOOL(state.enabled)});
    const label: ?id = if (state.label.len > 0) str(state.label) else null;
    v.msg(void, "setAccessibilityLabel:", .{label});
    const help: ?id = if (state.help.len > 0) str(state.help) else null;
    v.msg(void, "setToolTip:", .{help});
    v.msg(void, "setAccessibilityHelp:", .{help});
}

pub fn measure(state: platform.NativeControlState) ?platform.Size {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const v = create(state.kind) orelse return null;
    defer v.release();
    apply(v, state);
    const s = ak.msgStruct(ak.NSSize, v, "intrinsicContentSize", .{});
    const ins = ak.msgStruct(ak.NSEdgeInsets, v, "alignmentRectInsets", .{});
    // NSViewNoIntrinsicMetric (-1): the layout decides (sliders' width).
    const width: f64 = if (s.width < 0) 0 else s.width + ins.left + ins.right;
    const height: f64 = if (s.height < 0) 0 else s.height + ins.top + ins.bottom;
    return .{ .width = @floatCast(@ceil(width)), .height = @floatCast(@ceil(height)) };
}

pub fn attach(w: *MacWindow, state: platform.NativeControlState, z: platform.NativeViewZ) !platform.NativeViewId {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const v = create(state.kind) orelse return error.NativeControlUnsupported;
    defer v.release(); // the host keeps its own reference
    v.msg(void, "setAutoresizingMask:", .{@as(NSUInteger, 0)});
    v.msg(void, "setTarget:", .{target(w)});
    v.msg(void, "setAction:", .{objc.sel(action_selector)});
    // Clicking a control must not take the keyboard from zpui.
    v.msg(void, "setRefusesFirstResponder:", .{YES});
    apply(v, state);
    return native_views.attachControl(w, v, .{ .z = z }, state.kind);
}

pub fn update(w: *MacWindow, ident: platform.NativeViewId, state: platform.NativeControlState) void {
    const v = native_views.viewOf(w, ident) orelse return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    apply(v, state);
}
