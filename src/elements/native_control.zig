//! Native form controls (macOS: real AppKit controls hosted as native child views):
//! `nativeSwitch` (NSSwitch), `nativeCheckbox` (NSButton checkbox), `nativeSlider`
//! (NSSlider), `nativeSegmented` (NSSegmentedControl), `nativePopup` (NSPopUpButton)
//! and `nativeStepper` (NSStepper).
//!
//! ```zig
//! zpui.nativeSwitch("compact", .{ .on = s.compact, .label = "Compact mode" },
//!     cx.listener(View.onCompact),                 // fn(*View, *const NativeControlEvent, *Window, *Context(View))
//!     myDrawnSwitch(theme, s.compact))             // fallback: any element (or null)
//! zpui.nativeSlider("width", .{ .value = w, .min = 560, .max = 1200, .width = px(240) }, cx.listener(View.onWidth), fallback)
//! ```
//!
//! Where the window shows native controls (macOS), the element lays out at the control's
//! intrinsic frame size (`width` overrides the width; sliders have no intrinsic width),
//! places the control at its bounds every frame it is painted (clipped to the content
//! mask, hidden when not painted, so scrolled-out and unmounted controls disappear) and
//! pushes the state only when it differs from what the control shows, so a drag in
//! progress is never fought. User changes arrive as a `NativeControlEvent` (`.on`,
//! `.value` or `.index`) on the main thread inside an app update; the listener updates
//! the app's state, and the next frame confirms it (or, if the listener ignored it,
//! puts the app's value back). Disabled controls render AppKit's disabled look; the
//! appearance follows `Window.glass_dark` (the app theme) like Liquid Glass. Assistive
//! technology sees the AppKit control itself (`label` is its accessible name), and the
//! element adds no zpui accessibility node of its own.
//!
//! Elsewhere (Linux, Windows, the headless test platform unless a test opts in with
//! `TestWindow.native_controls`, or after `Window.setNativeControlsEnabled(false)`) the
//! element is exactly its `fallback`: same layout, paint, ids, listeners and
//! accessibility, so zpui-drawn controls keep working unchanged.
//!
//! Occlusion: controls in normal content sit under the overlay plane, so deferred
//! menus, popovers and dialogs cover them (and take the mouse while open). Controls
//! inside a deferred dialog or popover float above the overlay plane with it.

const std = @import("std");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const StyleBuilder = @import("../style/builder.zig").StyleBuilder;
const App = @import("../app/app.zig").App;
const Window = @import("../window/window.zig").Window;
const native_controls = @import("../window/native_controls.zig");
const element = @import("../window/element.zig");
const arena_mod = @import("../window/arena.zig");

const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds(Pixels);

pub const Kind = platform.NativeControlKind;
pub const ControlSize = platform.NativeControlSize;
pub const State = platform.NativeControlState;
pub const Event = platform.NativeControlEvent;
pub const Listener = native_controls.Listener;

pub const SwitchOptions = struct {
    on: bool,
    enabled: bool = true,
    label: []const u8 = "",
    help: []const u8 = "",
    size: ControlSize = .regular,
    width: ?Pixels = null,
};

pub const CheckboxOptions = struct {
    on: bool,
    /// Visible title next to the box ("" = a bare box; give `label` then).
    title: []const u8 = "",
    enabled: bool = true,
    label: []const u8 = "",
    help: []const u8 = "",
    size: ControlSize = .regular,
    width: ?Pixels = null,
};

pub const SliderOptions = struct {
    value: f64,
    min: f64 = 0,
    max: f64 = 1,
    /// > 0: tick marks every `step`, values snap to them.
    step: f64 = 0,
    enabled: bool = true,
    label: []const u8 = "",
    help: []const u8 = "",
    size: ControlSize = .regular,
    width: ?Pixels = null,
};

pub const ChoiceOptions = struct {
    items: []const []const u8,
    selected: ?u32,
    enabled: bool = true,
    label: []const u8 = "",
    help: []const u8 = "",
    size: ControlSize = .regular,
    width: ?Pixels = null,
};

pub const StepperOptions = struct {
    value: f64,
    min: f64 = 0,
    max: f64 = 100,
    step: f64 = 1,
    enabled: bool = true,
    label: []const u8 = "",
    help: []const u8 = "",
    size: ControlSize = .regular,
    width: ?Pixels = null,
};

/// An NSSwitch-style toggle; events carry `.on`.
pub fn nativeSwitch(id: anytype, opts: SwitchOptions, on_change: anytype, fallback: anytype) NativeControl {
    return nativeControl(id, .{ .kind = .switch_, .on = opts.on, .enabled = opts.enabled, .label = opts.label, .help = opts.help, .size = opts.size }, opts.width, on_change, fallback);
}

/// A checkbox (with an optional title); events carry `.on`.
pub fn nativeCheckbox(id: anytype, opts: CheckboxOptions, on_change: anytype, fallback: anytype) NativeControl {
    return nativeControl(id, .{ .kind = .checkbox, .on = opts.on, .title = opts.title, .enabled = opts.enabled, .label = if (opts.label.len > 0) opts.label else opts.title, .help = opts.help, .size = opts.size }, opts.width, on_change, fallback);
}

/// A continuous horizontal slider (or stepped with `step`); events carry `.value`.
pub fn nativeSlider(id: anytype, opts: SliderOptions, on_change: anytype, fallback: anytype) NativeControl {
    return nativeControl(id, .{ .kind = .slider, .value = opts.value, .min = opts.min, .max = opts.max, .step = opts.step, .enabled = opts.enabled, .label = opts.label, .help = opts.help, .size = opts.size }, opts.width, on_change, fallback);
}

/// A segmented control (select one); events carry `.index`.
pub fn nativeSegmented(id: anytype, opts: ChoiceOptions, on_change: anytype, fallback: anytype) NativeControl {
    return nativeControl(id, .{ .kind = .segmented, .items = opts.items, .selected = opts.selected, .enabled = opts.enabled, .label = opts.label, .help = opts.help, .size = opts.size }, opts.width, on_change, fallback);
}

/// A pop-up button (a simple select); events carry `.index`.
pub fn nativePopup(id: anytype, opts: ChoiceOptions, on_change: anytype, fallback: anytype) NativeControl {
    return nativeControl(id, .{ .kind = .popup, .items = opts.items, .selected = opts.selected, .enabled = opts.enabled, .label = opts.label, .help = opts.help, .size = opts.size }, opts.width, on_change, fallback);
}

/// Up/down arrows stepping a value; events carry `.value`.
pub fn nativeStepper(id: anytype, opts: StepperOptions, on_change: anytype, fallback: anytype) NativeControl {
    return nativeControl(id, .{ .kind = .stepper, .value = opts.value, .min = opts.min, .max = opts.max, .step = opts.step, .enabled = opts.enabled, .label = opts.label, .help = opts.help, .size = opts.size }, opts.width, on_change, fallback);
}

/// Whether `window` shows native controls (else every `native*` element is its fallback).
pub fn nativeControlsAvailable(window: *Window) bool {
    return window.measureNativeControl(.{ .kind = .switch_ }) != null;
}

pub const NativeControlData = struct {
    id: ElementId,
    state: State,
    width: ?Pixels,
    listener: ?Listener,
    fallback: ?AnyElement,
    /// Decided in request layout: the native control (true) or the fallback.
    native: bool = false,
};

/// Any native control from a full `State` (the typed constructors above wrap this).
pub fn nativeControl(id: anytype, state: State, width: ?Pixels, on_change: anytype, fallback: anytype) NativeControl {
    return .{ .d = arena_mod.current().create(NativeControlData, .{
        .id = ElementId.from(id),
        .state = state,
        .width = width,
        .listener = toListener(on_change),
        .fallback = toFallback(fallback),
    }) };
}

fn toListener(l: anytype) ?Listener {
    const L = @TypeOf(l);
    if (L == @TypeOf(null)) return null;
    if (L == ?Listener) return l;
    return Listener.init(l);
}

fn toFallback(f: anytype) ?AnyElement {
    const F = @TypeOf(f);
    if (F == @TypeOf(null)) return null;
    if (@typeInfo(F) == .optional) return if (f) |x| element.intoAnyElement(x) else null;
    return element.intoAnyElement(f);
}

pub const NativeControl = struct {
    d: *NativeControlData,

    pub fn intoAnyElement(self: NativeControl) AnyElement {
        return AnyElement.new(NativeControlElement{ .d = self.d });
    }
};

const NativeControlElement = struct {
    d: *NativeControlData,

    // No `elementId`: the fallback's ids stay exactly what they would be without the
    // wrapper; the native control's key is derived from `id` under the current scope.

    pub fn requestLayout(self: *NativeControlElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        const d = self.d;
        if (window.measureNativeControl(d.state)) |size| {
            d.native = true;
            var b = StyleBuilder.init.flexNone();
            const width = d.width orelse size.width;
            if (width > 0) b = b.w(geometry.px(width));
            if (size.height > 0) b = b.h(geometry.px(size.height));
            var s: style_mod.Style = .{};
            refine.refine(&s, b.refinement);
            return window.requestLayout(s, &.{});
        }
        d.native = false;
        if (d.fallback) |f| return f.requestLayout(window, cx);
        return window.requestLayout(.{}, &.{});
    }

    pub fn prepaint(self: *NativeControlElement, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        if (!self.d.native) if (self.d.fallback) |f| f.prepaint(window, cx);
    }

    pub fn paint(self: *NativeControlElement, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        const d = self.d;
        if (!d.native) {
            if (d.fallback) |f| f.paint(window, cx);
            return;
        }
        const gid = window.pushElementId(d.id);
        window.popElementId();
        _ = window.paintNativeControl(gid, d.state, bounds, d.listener);
    }
};
