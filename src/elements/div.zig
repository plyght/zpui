//! `div()` — the general-purpose container element (port of gpui `elements/div.rs`).
//!
//! ```zig
//! div().flex().flexCol().gap2().p4().roundedLg().bg(theme.card).shadowMd()
//!     .hover(sb.bg(theme.card_hover))           // sb = zpui.StyleBuilder.init
//!     .child("Title")
//!     .child(div().id("save").px3().py1().cursorPointer()
//!         .onClick(cx.listener(Self.onSave))
//!         .child("Save"))
//! ```
//!
//! `Div` is a cheap handle (one pointer into the frame arena), so builder calls copy nothing
//! big. `.id(x)` turns it into a `StatefulDiv` (gpui `Stateful<Div>`), which unlocks the
//! interactions that need state across frames: click, active style, drag, hover listener,
//! tooltip, focusable, scroll offsets.
//!
//! Listener arguments accept `cx.listener(Self.method)` / `cx.listenerWith(data, ...)`
//! results or plain functions `fn (*const Event, *Window, *App) void`.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const styled = @import("../styled.zig");
const zpui_styled = styled;
const input = @import("../input.zig");
const platform = @import("../platform/platform.zig");
const App = @import("../app/app.zig").App;
const entity_mod = @import("../app/entity.zig");
const EntityId = entity_mod.EntityId;
const context_mod = @import("../app/context.zig");
const Listener = context_mod.Listener;
const ListenerData = context_mod.ListenerData;
const KeyContext = @import("../app/key_context.zig").KeyContext;
const type_id = @import("../app/type_id.zig");
const TypeId = type_id.TypeId;
const executor = @import("../app/executor.zig");
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const Hitbox = window_mod.Hitbox;
const HitboxId = window_mod.HitboxId;
const DispatchPhase = window_mod.DispatchPhase;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const Children = element.Children;
const arena_mod = @import("../window/arena.zig");
const focus_mod = @import("../window/focus.zig");
const FocusHandle = focus_mod.FocusHandle;
const events = @import("../window/events.zig");
const ClickEvent = events.ClickEvent;
const AnyView = @import("../window/view.zig").AnyView;
const a11y = @import("../a11y.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);
const Style = style_mod.Style;
const StyleRefinement = style_mod.StyleRefinement;
const StyleBuilder = styled.StyleBuilder;

/// Create a div in the current frame arena.
pub fn div() Div {
    return .{ .d = arena_mod.current().create(DivData, .{}) };
}

pub const Div = DivImpl(false);
/// A div with an id (gpui `Stateful<Div>`).
pub const StatefulDiv = DivImpl(true);

/// Arena-resident data behind a `Div` handle.
pub const DivData = struct {
    interactivity: Interactivity = .{},
    children: Children = .{},
    /// Called after children prepaint with their bounds (gpui `on_children_prepainted`).
    children_prepainted: ?Listener([]const Bounds) = null,
};

fn toRefinement(x: anytype) StyleRefinement {
    const X = @TypeOf(x);
    if (X == StyleRefinement) return x;
    if (X == StyleBuilder) return x.refinement;
    @compileError("expected a StyleBuilder (zpui.StyleBuilder.init.bg(...)) or StyleRefinement, got " ++ @typeName(X));
}

fn arenaRefinement(x: anytype) *StyleRefinement {
    return arena_mod.current().create(StyleRefinement, toRefinement(x));
}

fn append(list: anytype, item: anytype) void {
    list.append(arena_mod.frameAllocator(), item) catch @panic("OOM");
}

/// Interactive builder methods shared by `Div`, `StatefulDiv` and `Svg` (gpui
/// `InteractiveElement` / `StatefulInteractiveElement`). `Self` must be a handle with a `d`
/// pointer to data holding an `interactivity: Interactivity` field.
pub fn InteractiveMethods(comptime Self: type, comptime stateful: bool) type {
    return struct {
        fn it(self: Self) *Interactivity {
            return &self.d.interactivity;
        }

        fn requireId(comptime what: []const u8) void {
            if (!stateful) @compileError(what ++ " needs an element id: call `.id(...)` first (gpui Stateful<Div>)");
        }

        // ---- interactive styles ------------------------------------------------------------

        /// Style applied while the mouse is over this element.
        pub fn hover(self: Self, s: anytype) Self {
            it(self).hover_style = arenaRefinement(s);
            return self;
        }

        /// Style applied while the mouse is over the element marked `.group(name)`.
        pub fn groupHover(self: Self, group_name: []const u8, s: anytype) Self {
            it(self).group_hover_style = .{ .group = group_name, .style = arenaRefinement(s) };
            return self;
        }

        /// Style applied while this element is pressed (needs an id).
        pub fn active(self: Self, s: anytype) Self {
            requireId("active");
            it(self).active_style = arenaRefinement(s);
            return self;
        }

        pub fn groupActive(self: Self, group_name: []const u8, s: anytype) Self {
            requireId("groupActive");
            it(self).group_active_style = .{ .group = group_name, .style = arenaRefinement(s) };
            return self;
        }

        /// Style applied while the tracked focus handle is focused (gpui `focus`).
        pub fn focusStyle(self: Self, s: anytype) Self {
            it(self).focus_style = arenaRefinement(s);
            return self;
        }

        /// Style applied while focus is within this element (gpui `in_focus`).
        pub fn inFocus(self: Self, s: anytype) Self {
            it(self).in_focus_style = arenaRefinement(s);
            return self;
        }

        /// Style applied while focused via the keyboard (gpui `focus_visible`).
        pub fn focusVisible(self: Self, s: anytype) Self {
            it(self).focus_visible_style = arenaRefinement(s);
            return self;
        }

        /// Style applied while a drag of `T` hovers this element.
        pub fn dragOver(self: Self, comptime T: type, s: anytype) Self {
            append(&it(self).drag_over_styles, DragOverStyle{ .type_id = type_id.typeId(T), .style = arenaRefinement(s) });
            return self;
        }

        pub fn groupDragOver(self: Self, group_name: []const u8, comptime T: type, s: anytype) Self {
            append(&it(self).group_drag_over_styles, GroupDragOverStyle{ .type_id = type_id.typeId(T), .group = group_name, .style = arenaRefinement(s) });
            return self;
        }

        /// Mark this element as group `name` for `groupHover` / `groupActive` (gpui `group`).
        pub fn group(self: Self, name: []const u8) Self {
            it(self).group = name;
            return self;
        }

        // ---- focus & keyboard -----------------------------------------------------------------

        /// Key context for keybindings, e.g. "Editor mode=full" (gpui `key_context`). Strings
        /// are parsed once per window; a `KeyContext` value must outlive the frames using it.
        pub fn keyContext(self: Self, ctx: anytype) Self {
            if (@TypeOf(ctx) == KeyContext) {
                it(self).key_context = .{ .parsed = ctx };
            } else {
                it(self).key_context = .{ .source = ctx };
            }
            return self;
        }

        /// Associate this element with `handle` (focus styles, focus on click, key dispatch).
        pub fn trackFocus(self: Self, handle: FocusHandle) Self {
            it(self).focusable = true;
            it(self).tracked_focus_handle = handle;
            return self;
        }

        /// Make this element focusable with a focus handle kept in its element state.
        pub fn focusable(self: Self) Self {
            requireId("focusable");
            it(self).focusable = true;
            return self;
        }

        pub fn tabIndex(self: Self, index: isize) Self {
            it(self).focusable = true;
            it(self).tab_index = index;
            it(self).tab_stop = true;
            return self;
        }

        pub fn tabStop(self: Self, stop: bool) Self {
            it(self).tab_stop = stop;
            return self;
        }

        pub fn tabGroup(self: Self) Self {
            it(self).tab_group = true;
            if (it(self).tab_index == null) it(self).tab_index = 0;
            return self;
        }

        pub fn onKeyDown(self: Self, l: anytype) Self {
            append(&it(self).key_down_listeners, KeyEntry(input.KeyDownEvent){ .listener = .init(l), .phase = .bubble });
            return self;
        }
        pub fn captureKeyDown(self: Self, l: anytype) Self {
            append(&it(self).key_down_listeners, KeyEntry(input.KeyDownEvent){ .listener = .init(l), .phase = .capture });
            return self;
        }
        pub fn onKeyUp(self: Self, l: anytype) Self {
            append(&it(self).key_up_listeners, KeyEntry(input.KeyUpEvent){ .listener = .init(l), .phase = .bubble });
            return self;
        }
        pub fn captureKeyUp(self: Self, l: anytype) Self {
            append(&it(self).key_up_listeners, KeyEntry(input.KeyUpEvent){ .listener = .init(l), .phase = .capture });
            return self;
        }
        pub fn onModifiersChanged(self: Self, l: anytype) Self {
            append(&it(self).modifiers_changed_listeners, Listener(input.ModifiersChangedEvent).init(l));
            return self;
        }

        /// Handle action `A` dispatched to this element or a descendant (bubble phase).
        pub fn onAction(self: Self, comptime A: type, l: anytype) Self {
            append(&it(self).action_listeners, ActionEntry.init(A, Listener(A).init(l), .bubble));
            return self;
        }
        /// Handle action `A` on the way down, before descendants see it.
        pub fn captureAction(self: Self, comptime A: type, l: anytype) Self {
            append(&it(self).action_listeners, ActionEntry.init(A, Listener(A).init(l), .capture));
            return self;
        }

        // ---- mouse --------------------------------------------------------------------------

        fn mouse(self: Self, comptime Ev: type, l: anytype, mode: MouseMode) Self {
            const entry: MouseEntry(Ev) = .{ .listener = .init(l), .mode = mode };
            switch (Ev) {
                input.MouseDownEvent => append(&it(self).mouse_down_listeners, entry),
                input.MouseUpEvent => append(&it(self).mouse_up_listeners, entry),
                input.MouseMoveEvent => append(&it(self).mouse_move_listeners, entry),
                input.MouseExitEvent => append(&it(self).mouse_exit_listeners, entry),
                input.ScrollWheelEvent => append(&it(self).scroll_wheel_listeners, entry),
                else => unreachable,
            }
            return self;
        }

        /// `button` pressed over this element (bubble phase).
        pub fn onMouseDown(self: Self, button: input.MouseButton, l: anytype) Self {
            return mouse(self, input.MouseDownEvent, l, .{ .bubble_button = button });
        }
        pub fn onAnyMouseDown(self: Self, l: anytype) Self {
            return mouse(self, input.MouseDownEvent, l, .bubble_any);
        }
        pub fn captureAnyMouseDown(self: Self, l: anytype) Self {
            return mouse(self, input.MouseDownEvent, l, .capture_any);
        }
        /// Any mouse down outside this element (capture phase), e.g. to dismiss popovers.
        pub fn onMouseDownOut(self: Self, l: anytype) Self {
            return mouse(self, input.MouseDownEvent, l, .out_any);
        }
        pub fn onMouseUp(self: Self, button: input.MouseButton, l: anytype) Self {
            return mouse(self, input.MouseUpEvent, l, .{ .bubble_button = button });
        }
        pub fn onAnyMouseUp(self: Self, l: anytype) Self {
            return mouse(self, input.MouseUpEvent, l, .bubble_any);
        }
        pub fn captureAnyMouseUp(self: Self, l: anytype) Self {
            return mouse(self, input.MouseUpEvent, l, .capture_any);
        }
        pub fn onMouseUpOut(self: Self, button: input.MouseButton, l: anytype) Self {
            return mouse(self, input.MouseUpEvent, l, .{ .out_button = button });
        }
        pub fn onMouseMove(self: Self, l: anytype) Self {
            return mouse(self, input.MouseMoveEvent, l, .bubble_any);
        }
        pub fn onMouseExit(self: Self, l: anytype) Self {
            return mouse(self, input.MouseExitEvent, l, .bubble_any);
        }
        pub fn onScrollWheel(self: Self, l: anytype) Self {
            return mouse(self, input.ScrollWheelEvent, l, .scroll);
        }

        /// Block mouse events from reaching elements behind this one (gpui `occlude`).
        pub fn occlude(self: Self) Self {
            it(self).hitbox_behavior = .block_mouse;
            return self;
        }
        pub fn blockMouseExceptScroll(self: Self) Self {
            it(self).hitbox_behavior = .block_mouse_except_scroll;
            return self;
        }

        // ---- drag and drop -----------------------------------------------------------------

        /// Accept drops of `T` (`l` receives `*const T`).
        pub fn onDrop(self: Self, comptime T: type, l: anytype) Self {
            append(&it(self).drop_listeners, DropEntry.init(T, Listener(T).init(l)));
            return self;
        }

        /// Decide whether a drag can be dropped here: `f(value: *const anyopaque, type_id, window, app) bool`.
        pub fn canDrop(self: Self, f: *const fn (*const anyopaque, TypeId, *Window, *App) bool) Self {
            it(self).can_drop = f;
            return self;
        }

        /// While a drag of `T` moves anywhere in the window (capture phase).
        pub fn onDragMove(self: Self, comptime T: type, l: anytype) Self {
            append(&it(self).drag_move_listeners, DragMoveEntry.init(T, Listener(events.DragMoveEvent(T)).init(l)));
            return self;
        }

        /// Start dragging `value` when the mouse moves past the threshold with the left button
        /// down. `build(value, cursor_offset, window, app)` returns the preview view entity
        /// (an owned `Entity(W)`). Needs an id.
        pub fn onDrag(self: Self, value: anytype, comptime build: anytype) Self {
            requireId("onDrag");
            it(self).drag = DragSpec.init(value, build);
            return self;
        }

        // ---- stateful interactions ---------------------------------------------------------

        /// Left click (mouse down + up over this element, or enter/space while focused).
        pub fn onClick(self: Self, l: anytype) Self {
            requireId("onClick");
            append(&it(self).click_listeners, Listener(ClickEvent).init(l));
            return self;
        }

        /// Clicks with buttons other than left.
        pub fn onAuxClick(self: Self, l: anytype) Self {
            requireId("onAuxClick");
            append(&it(self).aux_click_listeners, Listener(ClickEvent).init(l));
            return self;
        }

        /// Called with `true`/`false` when hover starts/ends.
        pub fn onHover(self: Self, l: anytype) Self {
            requireId("onHover");
            it(self).hover_listener = Listener(bool).init(l);
            return self;
        }

        /// Show a tooltip after hovering: `build(window, app)` returns an owned view entity.
        /// Use `tooltipWith` to pass data (e.g. a static string) to the builder.
        pub fn tooltip(self: Self, comptime build: anytype) Self {
            requireId("tooltip");
            it(self).tooltip = TooltipBuilder.init(build, {});
            return self;
        }

        /// Like `tooltip` with up to 24 bytes of data: `build(data, window, app)`.
        pub fn tooltipWith(self: Self, data: anytype, comptime build: anytype) Self {
            requireId("tooltip");
            it(self).tooltip = TooltipBuilder.init(build, data);
            return self;
        }

        pub fn hoverableTooltip(self: Self, comptime build: anytype) Self {
            requireId("tooltip");
            var t = TooltipBuilder.init(build, {});
            t.hoverable = true;
            it(self).tooltip = t;
            return self;
        }

        pub fn tooltipShowDelay(self: Self, delay_ns: u64) Self {
            it(self).tooltip_show_delay_ns = delay_ns;
            return self;
        }

        /// Share scroll state with `handle` (offset, programmatic scrolling).
        pub fn trackScroll(self: Self, handle: ScrollHandle) Self {
            it(self).tracked_scroll_handle = handle;
            return self;
        }

        // ---- accessibility (zui `StatefulInteractiveElement::role` / `aria_*`) --------------
        // An element joins the accessibility tree when it has an id and a role. Text inside
        // it names it (buttons, tabs, ...) unless `ariaLabel` is set.

        fn aria(self: Self) *a11y.Info {
            const i = it(self);
            if (i.aria == null) i.aria = arena_mod.current().create(a11y.Info, .{});
            return i.aria.?;
        }

        /// The accessible role (gpui `role(Role::Button)`). Needs an id.
        pub fn role(self: Self, r: a11y.Role) Self {
            requireId("role");
            it(self).a11y_role = r;
            return self;
        }
        /// The accessible name (`aria-label`). The string must outlive the frame.
        pub fn ariaLabel(self: Self, label: []const u8) Self {
            requireId("ariaLabel");
            aria(self).label = label;
            return self;
        }
        /// Supplementary text announced after the name (`aria-description`).
        pub fn ariaDescription(self: Self, text: []const u8) Self {
            requireId("ariaDescription");
            aria(self).description = text;
            return self;
        }
        /// The shortcut announced for this control (`aria-keyshortcuts`); no keymap.
        pub fn ariaKeyshortcuts(self: Self, keys: []const u8) Self {
            requireId("ariaKeyshortcuts");
            aria(self).keyshortcuts = keys;
            return self;
        }
        /// Report this element as focused while a focused ancestor holds keyboard focus
        /// (`aria-activedescendant`, set on the selected child of a menu/list box).
        pub fn ariaActiveDescendant(self: Self) Self {
            requireId("ariaActiveDescendant");
            aria(self).active_descendant = true;
            return self;
        }
        pub fn ariaSelected(self: Self, selected: bool) Self {
            requireId("ariaSelected");
            aria(self).selected = selected;
            return self;
        }
        pub fn ariaExpanded(self: Self, expanded: bool) Self {
            requireId("ariaExpanded");
            aria(self).expanded = expanded;
            return self;
        }
        /// Toggle state: a `bool` or `a11y.Toggled` (`.mixed`).
        pub fn ariaToggled(self: Self, toggled: anytype) Self {
            requireId("ariaToggled");
            aria(self).toggled = if (@TypeOf(toggled) == bool) (if (toggled) .on else .off) else toggled;
            return self;
        }
        pub fn ariaDisabled(self: Self, disabled: bool) Self {
            requireId("ariaDisabled");
            aria(self).disabled = disabled;
            return self;
        }
        pub fn ariaReadOnly(self: Self, read_only: bool) Self {
            requireId("ariaReadOnly");
            aria(self).read_only = read_only;
            return self;
        }
        /// String value (a text field's contents).
        pub fn ariaValue(self: Self, value: []const u8) Self {
            requireId("ariaValue");
            aria(self).value = value;
            return self;
        }
        /// A text field's caret / selection (UTF-8 byte offsets into its value; `focus` is
        /// the caret). Bridges report it (AT-SPI Text caret + selection, AXSelectedTextRange).
        pub fn ariaTextSelection(self: Self, anchor: usize, focus: usize) Self {
            requireId("ariaTextSelection");
            aria(self).text_selection = .{ .anchor = @intCast(anchor), .focus = @intCast(focus) };
            return self;
        }
        /// A link's target URL (AT-SPI Hyperlink, AXURL). The string must outlive the frame.
        pub fn ariaUrl(self: Self, url: []const u8) Self {
            requireId("ariaUrl");
            aria(self).url = url;
            return self;
        }
        /// Placeholder announced while a text field is empty.
        pub fn ariaPlaceholder(self: Self, text: []const u8) Self {
            requireId("ariaPlaceholder");
            aria(self).placeholder = text;
            return self;
        }
        pub fn ariaNumericValue(self: Self, v: f64) Self {
            requireId("ariaNumericValue");
            aria(self).numeric_value = v;
            return self;
        }
        pub fn ariaNumericValueStep(self: Self, v: f64) Self {
            requireId("ariaNumericValueStep");
            aria(self).numeric_value_step = v;
            return self;
        }
        pub fn ariaMinNumericValue(self: Self, v: f64) Self {
            requireId("ariaMinNumericValue");
            aria(self).min_numeric_value = v;
            return self;
        }
        pub fn ariaMaxNumericValue(self: Self, v: f64) Self {
            requireId("ariaMaxNumericValue");
            aria(self).max_numeric_value = v;
            return self;
        }
        pub fn ariaOrientation(self: Self, o: a11y.Orientation) Self {
            requireId("ariaOrientation");
            aria(self).orientation = o;
            return self;
        }
        /// Heading / tree level.
        pub fn ariaLevel(self: Self, level: usize) Self {
            requireId("ariaLevel");
            aria(self).level = @intCast(level);
            return self;
        }
        pub fn ariaPositionInSet(self: Self, position: usize) Self {
            requireId("ariaPositionInSet");
            aria(self).position_in_set = @intCast(position);
            return self;
        }
        pub fn ariaSizeOfSet(self: Self, size: usize) Self {
            requireId("ariaSizeOfSet");
            aria(self).size_of_set = @intCast(size);
            return self;
        }
        pub fn ariaRowIndex(self: Self, index: usize) Self {
            requireId("ariaRowIndex");
            aria(self).row_index = @intCast(index);
            return self;
        }
        pub fn ariaColumnIndex(self: Self, index: usize) Self {
            requireId("ariaColumnIndex");
            aria(self).column_index = @intCast(index);
            return self;
        }
        pub fn ariaRowCount(self: Self, count: usize) Self {
            requireId("ariaRowCount");
            aria(self).row_count = @intCast(count);
            return self;
        }
        pub fn ariaColumnCount(self: Self, count: usize) Self {
            requireId("ariaColumnCount");
            aria(self).column_count = @intCast(count);
            return self;
        }
        /// Handle an assistive-technology request (`l` gets `*const a11y.ActionRequest`);
        /// overrides the built-in behaviour for that action (zui `on_a11y_action`).
        pub fn onA11yAction(self: Self, action: a11y.Action, l: anytype) Self {
            requireId("onA11yAction");
            append(&it(self).a11y_action_listeners, A11yActionEntry{ .action = action, .listener = Listener(a11y.ActionRequest).init(l) });
            return self;
        }
    };
}

const A11yActionEntry = struct { action: a11y.Action, listener: Listener(a11y.ActionRequest) };

fn DivImpl(comptime stateful: bool) type {
    return struct {
        const Self = @This();
        pub const is_stateful = stateful;

        d: *DivData,

        fn it(self: Self) *Interactivity {
            return &self.d.interactivity;
        }

        fn requireId(comptime what: []const u8) void {
            if (!stateful) @compileError(what ++ " needs an element id: call `.id(...)` first (gpui Stateful<Div>)");
        }

        /// The base style (for the `Styled` builder methods).
        pub fn style(self: *Self) *StyleRefinement {
            return &self.d.interactivity.base_style;
        }

        // ---- element plumbing --------------------------------------------------------------

        pub fn intoAnyElement(self: Self) AnyElement {
            return AnyElement.new(DivElement{ .d = self.d });
        }

        /// Give this div an id so its state persists across frames (gpui `id`).
        pub fn id(self: Self, element_id: anytype) StatefulDiv {
            self.it().element_id = ElementId.from(element_id);
            return .{ .d = self.d };
        }

        // ---- children -------------------------------------------------------------------------

        /// Append a child: an element, `Div`, string, view entity, component, `AnyElement`,
        /// or an optional of those (null adds nothing visible).
        pub fn child(self: Self, c: anytype) Self {
            self.d.children.add(c);
            return self;
        }

        /// Append a tuple or slice of children.
        pub fn children(self: Self, list: anytype) Self {
            self.d.children.addMany(list);
            return self;
        }

        /// Call `method(self, args...)` only if `condition` holds (gpui `when`):
        /// `.when(selected, Div.bg, .{theme.accent})`.
        pub fn when(self: Self, condition: bool, comptime method: anytype, args: anytype) Self {
            return if (condition) @call(.auto, method, .{self} ++ args) else self;
        }

        /// Merge a whole refinement into the base style.
        pub fn refineStyle(self: Self, s: anytype) Self {
            refine.refine(&self.it().base_style, toRefinement(s));
            return self;
        }

        /// Merge `s` into the base style if `condition` holds.
        pub fn refineStyleIf(self: Self, condition: bool, s: anytype) Self {
            if (condition) refine.refine(&self.it().base_style, toRefinement(s));
            return self;
        }

        pub fn onChildrenPrepainted(self: Self, l: anytype) Self {
            self.d.children_prepainted = Listener([]const Bounds).init(l);
            return self;
        }

        // Interactive builder methods (shared with `Svg`, see `InteractiveMethods`).
        const IM = InteractiveMethods(Self, stateful);
        pub const hover = IM.hover;
        pub const groupHover = IM.groupHover;
        pub const active = IM.active;
        pub const groupActive = IM.groupActive;
        pub const focusStyle = IM.focusStyle;
        pub const inFocus = IM.inFocus;
        pub const focusVisible = IM.focusVisible;
        pub const dragOver = IM.dragOver;
        pub const groupDragOver = IM.groupDragOver;
        pub const group = IM.group;
        pub const keyContext = IM.keyContext;
        pub const trackFocus = IM.trackFocus;
        pub const focusable = IM.focusable;
        pub const tabIndex = IM.tabIndex;
        pub const tabStop = IM.tabStop;
        pub const tabGroup = IM.tabGroup;
        pub const onKeyDown = IM.onKeyDown;
        pub const captureKeyDown = IM.captureKeyDown;
        pub const onKeyUp = IM.onKeyUp;
        pub const captureKeyUp = IM.captureKeyUp;
        pub const onModifiersChanged = IM.onModifiersChanged;
        pub const onAction = IM.onAction;
        pub const captureAction = IM.captureAction;
        pub const onMouseDown = IM.onMouseDown;
        pub const onAnyMouseDown = IM.onAnyMouseDown;
        pub const captureAnyMouseDown = IM.captureAnyMouseDown;
        pub const onMouseDownOut = IM.onMouseDownOut;
        pub const onMouseUp = IM.onMouseUp;
        pub const onAnyMouseUp = IM.onAnyMouseUp;
        pub const captureAnyMouseUp = IM.captureAnyMouseUp;
        pub const onMouseUpOut = IM.onMouseUpOut;
        pub const onMouseMove = IM.onMouseMove;
        pub const onMouseExit = IM.onMouseExit;
        pub const onScrollWheel = IM.onScrollWheel;
        pub const occlude = IM.occlude;
        pub const blockMouseExceptScroll = IM.blockMouseExceptScroll;
        pub const onDrop = IM.onDrop;
        pub const canDrop = IM.canDrop;
        pub const onDragMove = IM.onDragMove;
        pub const onDrag = IM.onDrag;
        pub const onClick = IM.onClick;
        pub const onAuxClick = IM.onAuxClick;
        pub const onHover = IM.onHover;
        pub const tooltip = IM.tooltip;
        pub const tooltipWith = IM.tooltipWith;
        pub const hoverableTooltip = IM.hoverableTooltip;
        pub const tooltipShowDelay = IM.tooltipShowDelay;
        pub const trackScroll = IM.trackScroll;
        pub const role = IM.role;
        pub const ariaLabel = IM.ariaLabel;
        pub const ariaDescription = IM.ariaDescription;
        pub const ariaKeyshortcuts = IM.ariaKeyshortcuts;
        pub const ariaActiveDescendant = IM.ariaActiveDescendant;
        pub const ariaSelected = IM.ariaSelected;
        pub const ariaExpanded = IM.ariaExpanded;
        pub const ariaToggled = IM.ariaToggled;
        pub const ariaDisabled = IM.ariaDisabled;
        pub const ariaReadOnly = IM.ariaReadOnly;
        pub const ariaValue = IM.ariaValue;
        pub const ariaPlaceholder = IM.ariaPlaceholder;
        pub const ariaTextSelection = IM.ariaTextSelection;
        pub const ariaUrl = IM.ariaUrl;
        pub const ariaNumericValue = IM.ariaNumericValue;
        pub const ariaNumericValueStep = IM.ariaNumericValueStep;
        pub const ariaMinNumericValue = IM.ariaMinNumericValue;
        pub const ariaMaxNumericValue = IM.ariaMaxNumericValue;
        pub const ariaOrientation = IM.ariaOrientation;
        pub const ariaLevel = IM.ariaLevel;
        pub const ariaPositionInSet = IM.ariaPositionInSet;
        pub const ariaSizeOfSet = IM.ariaSizeOfSet;
        pub const ariaRowIndex = IM.ariaRowIndex;
        pub const ariaColumnIndex = IM.ariaColumnIndex;
        pub const ariaRowCount = IM.ariaRowCount;
        pub const ariaColumnCount = IM.ariaColumnCount;
        pub const onA11yAction = IM.onA11yAction;

        // Animation wrappers (src/elements/animation.zig, gpui `AnimationExt`).
        pub const withAnimation = @import("animation.zig").Ext(Self).withAnimation;
        pub const withAnimationCtx = @import("animation.zig").Ext(Self).withAnimationCtx;
        pub const withAnimations = @import("animation.zig").Ext(Self).withAnimations;

        // Generated Styled forwarders (scripts/gen_styled.py --forward src/elements/div.zig).
        // zpui:styled-forwarders begin(Self)
        const StyledMethods = zpui_styled.Styled(Self);
        const GeneratedStyledMethods = zpui_styled.Generated(Self);
        pub const textStyle = StyledMethods.textStyle;
        pub const block = StyledMethods.block;
        pub const flex = StyledMethods.flex;
        pub const hidden = StyledMethods.hidden;
        pub const scrollbarWidth = StyledMethods.scrollbarWidth;
        pub const overflowScroll = StyledMethods.overflowScroll;
        pub const overflowXScroll = StyledMethods.overflowXScroll;
        pub const overflowYScroll = StyledMethods.overflowYScroll;
        pub const whitespaceNormal = StyledMethods.whitespaceNormal;
        pub const whitespaceNowrap = StyledMethods.whitespaceNowrap;
        pub const textEllipsis = StyledMethods.textEllipsis;
        pub const textEllipsisStart = StyledMethods.textEllipsisStart;
        pub const textEllipsisMiddle = StyledMethods.textEllipsisMiddle;
        pub const textOverflow = StyledMethods.textOverflow;
        pub const textAlign = StyledMethods.textAlign;
        pub const textLeft = StyledMethods.textLeft;
        pub const textCenter = StyledMethods.textCenter;
        pub const textRight = StyledMethods.textRight;
        pub const truncate = StyledMethods.truncate;
        pub const lineClamp = StyledMethods.lineClamp;
        pub const flexCol = StyledMethods.flexCol;
        pub const flexColReverse = StyledMethods.flexColReverse;
        pub const flexRow = StyledMethods.flexRow;
        pub const flexRowReverse = StyledMethods.flexRowReverse;
        pub const flex1 = StyledMethods.flex1;
        pub const flexAuto = StyledMethods.flexAuto;
        pub const flexInitial = StyledMethods.flexInitial;
        pub const flexNone = StyledMethods.flexNone;
        pub const flexBasis = StyledMethods.flexBasis;
        pub const flexGrow = StyledMethods.flexGrow;
        pub const flexGrow0 = StyledMethods.flexGrow0;
        pub const flexGrow1 = StyledMethods.flexGrow1;
        pub const flexShrink = StyledMethods.flexShrink;
        pub const flexShrink0 = StyledMethods.flexShrink0;
        pub const flexShrink1 = StyledMethods.flexShrink1;
        pub const flexWrap = StyledMethods.flexWrap;
        pub const flexWrapReverse = StyledMethods.flexWrapReverse;
        pub const flexNowrap = StyledMethods.flexNowrap;
        pub const itemsStart = StyledMethods.itemsStart;
        pub const itemsEnd = StyledMethods.itemsEnd;
        pub const itemsCenter = StyledMethods.itemsCenter;
        pub const itemsBaseline = StyledMethods.itemsBaseline;
        pub const itemsStretch = StyledMethods.itemsStretch;
        pub const selfStart = StyledMethods.selfStart;
        pub const selfEnd = StyledMethods.selfEnd;
        pub const selfFlexStart = StyledMethods.selfFlexStart;
        pub const selfFlexEnd = StyledMethods.selfFlexEnd;
        pub const selfCenter = StyledMethods.selfCenter;
        pub const selfBaseline = StyledMethods.selfBaseline;
        pub const selfStretch = StyledMethods.selfStretch;
        pub const justifyStart = StyledMethods.justifyStart;
        pub const justifyEnd = StyledMethods.justifyEnd;
        pub const justifyCenter = StyledMethods.justifyCenter;
        pub const justifyBetween = StyledMethods.justifyBetween;
        pub const justifyAround = StyledMethods.justifyAround;
        pub const justifyEvenly = StyledMethods.justifyEvenly;
        pub const contentNormal = StyledMethods.contentNormal;
        pub const contentCenter = StyledMethods.contentCenter;
        pub const contentStart = StyledMethods.contentStart;
        pub const contentEnd = StyledMethods.contentEnd;
        pub const contentBetween = StyledMethods.contentBetween;
        pub const contentAround = StyledMethods.contentAround;
        pub const contentEvenly = StyledMethods.contentEvenly;
        pub const contentStretch = StyledMethods.contentStretch;
        pub const aspectRatio = StyledMethods.aspectRatio;
        pub const aspectSquare = StyledMethods.aspectSquare;
        pub const bg = StyledMethods.bg;
        pub const borderColor = StyledMethods.borderColor;
        pub const borderDashed = StyledMethods.borderDashed;
        pub const shadow = StyledMethods.shadow;
        pub const shadowNone = StyledMethods.shadowNone;
        pub const opacity = StyledMethods.opacity;
        pub const cursor = StyledMethods.cursor;
        pub const debug = StyledMethods.debug;
        pub const debugBelow = StyledMethods.debugBelow;
        pub const textColor = StyledMethods.textColor;
        pub const textBg = StyledMethods.textBg;
        pub const fontWeight = StyledMethods.fontWeight;
        pub const textSize = StyledMethods.textSize;
        pub const textXs = StyledMethods.textXs;
        pub const textSm = StyledMethods.textSm;
        pub const textBase = StyledMethods.textBase;
        pub const textLg = StyledMethods.textLg;
        pub const textXl = StyledMethods.textXl;
        pub const text2xl = StyledMethods.text2xl;
        pub const text3xl = StyledMethods.text3xl;
        pub const italic = StyledMethods.italic;
        pub const notItalic = StyledMethods.notItalic;
        pub const underline = StyledMethods.underline;
        pub const lineThrough = StyledMethods.lineThrough;
        pub const textDecorationNone = StyledMethods.textDecorationNone;
        pub const textDecorationColor = StyledMethods.textDecorationColor;
        pub const textDecorationSolid = StyledMethods.textDecorationSolid;
        pub const textDecorationWavy = StyledMethods.textDecorationWavy;
        pub const textDecoration0 = StyledMethods.textDecoration0;
        pub const textDecoration1 = StyledMethods.textDecoration1;
        pub const textDecoration2 = StyledMethods.textDecoration2;
        pub const textDecoration4 = StyledMethods.textDecoration4;
        pub const textDecoration8 = StyledMethods.textDecoration8;
        pub const fontFamily = StyledMethods.fontFamily;
        pub const fontFeatures = StyledMethods.fontFeatures;
        pub const font = StyledMethods.font;
        pub const lineHeight = StyledMethods.lineHeight;
        pub const w = GeneratedStyledMethods.w;
        pub const w0 = GeneratedStyledMethods.w0;
        pub const w0p5 = GeneratedStyledMethods.w0p5;
        pub const w1 = GeneratedStyledMethods.w1;
        pub const w1p5 = GeneratedStyledMethods.w1p5;
        pub const w2 = GeneratedStyledMethods.w2;
        pub const w2p5 = GeneratedStyledMethods.w2p5;
        pub const w3 = GeneratedStyledMethods.w3;
        pub const w3p5 = GeneratedStyledMethods.w3p5;
        pub const w4 = GeneratedStyledMethods.w4;
        pub const w5 = GeneratedStyledMethods.w5;
        pub const w6 = GeneratedStyledMethods.w6;
        pub const w7 = GeneratedStyledMethods.w7;
        pub const w8 = GeneratedStyledMethods.w8;
        pub const w9 = GeneratedStyledMethods.w9;
        pub const w10 = GeneratedStyledMethods.w10;
        pub const w11 = GeneratedStyledMethods.w11;
        pub const w12 = GeneratedStyledMethods.w12;
        pub const w16 = GeneratedStyledMethods.w16;
        pub const w20 = GeneratedStyledMethods.w20;
        pub const w24 = GeneratedStyledMethods.w24;
        pub const w32 = GeneratedStyledMethods.w32;
        pub const w40 = GeneratedStyledMethods.w40;
        pub const w48 = GeneratedStyledMethods.w48;
        pub const w56 = GeneratedStyledMethods.w56;
        pub const w64 = GeneratedStyledMethods.w64;
        pub const w72 = GeneratedStyledMethods.w72;
        pub const w80 = GeneratedStyledMethods.w80;
        pub const w96 = GeneratedStyledMethods.w96;
        pub const w112 = GeneratedStyledMethods.w112;
        pub const w128 = GeneratedStyledMethods.w128;
        pub const wAuto = GeneratedStyledMethods.wAuto;
        pub const wPx = GeneratedStyledMethods.wPx;
        pub const wFull = GeneratedStyledMethods.wFull;
        pub const w1_2 = GeneratedStyledMethods.w1_2;
        pub const w1_3 = GeneratedStyledMethods.w1_3;
        pub const w2_3 = GeneratedStyledMethods.w2_3;
        pub const w1_4 = GeneratedStyledMethods.w1_4;
        pub const w2_4 = GeneratedStyledMethods.w2_4;
        pub const w3_4 = GeneratedStyledMethods.w3_4;
        pub const w1_5 = GeneratedStyledMethods.w1_5;
        pub const w2_5 = GeneratedStyledMethods.w2_5;
        pub const w3_5 = GeneratedStyledMethods.w3_5;
        pub const w4_5 = GeneratedStyledMethods.w4_5;
        pub const w1_6 = GeneratedStyledMethods.w1_6;
        pub const w5_6 = GeneratedStyledMethods.w5_6;
        pub const w1_12 = GeneratedStyledMethods.w1_12;
        pub const h = GeneratedStyledMethods.h;
        pub const h0 = GeneratedStyledMethods.h0;
        pub const h0p5 = GeneratedStyledMethods.h0p5;
        pub const h1 = GeneratedStyledMethods.h1;
        pub const h1p5 = GeneratedStyledMethods.h1p5;
        pub const h2 = GeneratedStyledMethods.h2;
        pub const h2p5 = GeneratedStyledMethods.h2p5;
        pub const h3 = GeneratedStyledMethods.h3;
        pub const h3p5 = GeneratedStyledMethods.h3p5;
        pub const h4 = GeneratedStyledMethods.h4;
        pub const h5 = GeneratedStyledMethods.h5;
        pub const h6 = GeneratedStyledMethods.h6;
        pub const h7 = GeneratedStyledMethods.h7;
        pub const h8 = GeneratedStyledMethods.h8;
        pub const h9 = GeneratedStyledMethods.h9;
        pub const h10 = GeneratedStyledMethods.h10;
        pub const h11 = GeneratedStyledMethods.h11;
        pub const h12 = GeneratedStyledMethods.h12;
        pub const h16 = GeneratedStyledMethods.h16;
        pub const h20 = GeneratedStyledMethods.h20;
        pub const h24 = GeneratedStyledMethods.h24;
        pub const h32 = GeneratedStyledMethods.h32;
        pub const h40 = GeneratedStyledMethods.h40;
        pub const h48 = GeneratedStyledMethods.h48;
        pub const h56 = GeneratedStyledMethods.h56;
        pub const h64 = GeneratedStyledMethods.h64;
        pub const h72 = GeneratedStyledMethods.h72;
        pub const h80 = GeneratedStyledMethods.h80;
        pub const h96 = GeneratedStyledMethods.h96;
        pub const h112 = GeneratedStyledMethods.h112;
        pub const h128 = GeneratedStyledMethods.h128;
        pub const hAuto = GeneratedStyledMethods.hAuto;
        pub const hPx = GeneratedStyledMethods.hPx;
        pub const hFull = GeneratedStyledMethods.hFull;
        pub const h1_2 = GeneratedStyledMethods.h1_2;
        pub const h1_3 = GeneratedStyledMethods.h1_3;
        pub const h2_3 = GeneratedStyledMethods.h2_3;
        pub const h1_4 = GeneratedStyledMethods.h1_4;
        pub const h2_4 = GeneratedStyledMethods.h2_4;
        pub const h3_4 = GeneratedStyledMethods.h3_4;
        pub const h1_5 = GeneratedStyledMethods.h1_5;
        pub const h2_5 = GeneratedStyledMethods.h2_5;
        pub const h3_5 = GeneratedStyledMethods.h3_5;
        pub const h4_5 = GeneratedStyledMethods.h4_5;
        pub const h1_6 = GeneratedStyledMethods.h1_6;
        pub const h5_6 = GeneratedStyledMethods.h5_6;
        pub const h1_12 = GeneratedStyledMethods.h1_12;
        pub const size = GeneratedStyledMethods.size;
        pub const size0 = GeneratedStyledMethods.size0;
        pub const size0p5 = GeneratedStyledMethods.size0p5;
        pub const size1 = GeneratedStyledMethods.size1;
        pub const size1p5 = GeneratedStyledMethods.size1p5;
        pub const size2 = GeneratedStyledMethods.size2;
        pub const size2p5 = GeneratedStyledMethods.size2p5;
        pub const size3 = GeneratedStyledMethods.size3;
        pub const size3p5 = GeneratedStyledMethods.size3p5;
        pub const size4 = GeneratedStyledMethods.size4;
        pub const size5 = GeneratedStyledMethods.size5;
        pub const size6 = GeneratedStyledMethods.size6;
        pub const size7 = GeneratedStyledMethods.size7;
        pub const size8 = GeneratedStyledMethods.size8;
        pub const size9 = GeneratedStyledMethods.size9;
        pub const size10 = GeneratedStyledMethods.size10;
        pub const size11 = GeneratedStyledMethods.size11;
        pub const size12 = GeneratedStyledMethods.size12;
        pub const size16 = GeneratedStyledMethods.size16;
        pub const size20 = GeneratedStyledMethods.size20;
        pub const size24 = GeneratedStyledMethods.size24;
        pub const size32 = GeneratedStyledMethods.size32;
        pub const size40 = GeneratedStyledMethods.size40;
        pub const size48 = GeneratedStyledMethods.size48;
        pub const size56 = GeneratedStyledMethods.size56;
        pub const size64 = GeneratedStyledMethods.size64;
        pub const size72 = GeneratedStyledMethods.size72;
        pub const size80 = GeneratedStyledMethods.size80;
        pub const size96 = GeneratedStyledMethods.size96;
        pub const size112 = GeneratedStyledMethods.size112;
        pub const size128 = GeneratedStyledMethods.size128;
        pub const sizeAuto = GeneratedStyledMethods.sizeAuto;
        pub const sizePx = GeneratedStyledMethods.sizePx;
        pub const sizeFull = GeneratedStyledMethods.sizeFull;
        pub const size1_2 = GeneratedStyledMethods.size1_2;
        pub const size1_3 = GeneratedStyledMethods.size1_3;
        pub const size2_3 = GeneratedStyledMethods.size2_3;
        pub const size1_4 = GeneratedStyledMethods.size1_4;
        pub const size2_4 = GeneratedStyledMethods.size2_4;
        pub const size3_4 = GeneratedStyledMethods.size3_4;
        pub const size1_5 = GeneratedStyledMethods.size1_5;
        pub const size2_5 = GeneratedStyledMethods.size2_5;
        pub const size3_5 = GeneratedStyledMethods.size3_5;
        pub const size4_5 = GeneratedStyledMethods.size4_5;
        pub const size1_6 = GeneratedStyledMethods.size1_6;
        pub const size5_6 = GeneratedStyledMethods.size5_6;
        pub const size1_12 = GeneratedStyledMethods.size1_12;
        pub const minSize = GeneratedStyledMethods.minSize;
        pub const minSize0 = GeneratedStyledMethods.minSize0;
        pub const minSize0p5 = GeneratedStyledMethods.minSize0p5;
        pub const minSize1 = GeneratedStyledMethods.minSize1;
        pub const minSize1p5 = GeneratedStyledMethods.minSize1p5;
        pub const minSize2 = GeneratedStyledMethods.minSize2;
        pub const minSize2p5 = GeneratedStyledMethods.minSize2p5;
        pub const minSize3 = GeneratedStyledMethods.minSize3;
        pub const minSize3p5 = GeneratedStyledMethods.minSize3p5;
        pub const minSize4 = GeneratedStyledMethods.minSize4;
        pub const minSize5 = GeneratedStyledMethods.minSize5;
        pub const minSize6 = GeneratedStyledMethods.minSize6;
        pub const minSize7 = GeneratedStyledMethods.minSize7;
        pub const minSize8 = GeneratedStyledMethods.minSize8;
        pub const minSize9 = GeneratedStyledMethods.minSize9;
        pub const minSize10 = GeneratedStyledMethods.minSize10;
        pub const minSize11 = GeneratedStyledMethods.minSize11;
        pub const minSize12 = GeneratedStyledMethods.minSize12;
        pub const minSize16 = GeneratedStyledMethods.minSize16;
        pub const minSize20 = GeneratedStyledMethods.minSize20;
        pub const minSize24 = GeneratedStyledMethods.minSize24;
        pub const minSize32 = GeneratedStyledMethods.minSize32;
        pub const minSize40 = GeneratedStyledMethods.minSize40;
        pub const minSize48 = GeneratedStyledMethods.minSize48;
        pub const minSize56 = GeneratedStyledMethods.minSize56;
        pub const minSize64 = GeneratedStyledMethods.minSize64;
        pub const minSize72 = GeneratedStyledMethods.minSize72;
        pub const minSize80 = GeneratedStyledMethods.minSize80;
        pub const minSize96 = GeneratedStyledMethods.minSize96;
        pub const minSize112 = GeneratedStyledMethods.minSize112;
        pub const minSize128 = GeneratedStyledMethods.minSize128;
        pub const minSizeAuto = GeneratedStyledMethods.minSizeAuto;
        pub const minSizePx = GeneratedStyledMethods.minSizePx;
        pub const minSizeFull = GeneratedStyledMethods.minSizeFull;
        pub const minSize1_2 = GeneratedStyledMethods.minSize1_2;
        pub const minSize1_3 = GeneratedStyledMethods.minSize1_3;
        pub const minSize2_3 = GeneratedStyledMethods.minSize2_3;
        pub const minSize1_4 = GeneratedStyledMethods.minSize1_4;
        pub const minSize2_4 = GeneratedStyledMethods.minSize2_4;
        pub const minSize3_4 = GeneratedStyledMethods.minSize3_4;
        pub const minSize1_5 = GeneratedStyledMethods.minSize1_5;
        pub const minSize2_5 = GeneratedStyledMethods.minSize2_5;
        pub const minSize3_5 = GeneratedStyledMethods.minSize3_5;
        pub const minSize4_5 = GeneratedStyledMethods.minSize4_5;
        pub const minSize1_6 = GeneratedStyledMethods.minSize1_6;
        pub const minSize5_6 = GeneratedStyledMethods.minSize5_6;
        pub const minSize1_12 = GeneratedStyledMethods.minSize1_12;
        pub const minW = GeneratedStyledMethods.minW;
        pub const minW0 = GeneratedStyledMethods.minW0;
        pub const minW0p5 = GeneratedStyledMethods.minW0p5;
        pub const minW1 = GeneratedStyledMethods.minW1;
        pub const minW1p5 = GeneratedStyledMethods.minW1p5;
        pub const minW2 = GeneratedStyledMethods.minW2;
        pub const minW2p5 = GeneratedStyledMethods.minW2p5;
        pub const minW3 = GeneratedStyledMethods.minW3;
        pub const minW3p5 = GeneratedStyledMethods.minW3p5;
        pub const minW4 = GeneratedStyledMethods.minW4;
        pub const minW5 = GeneratedStyledMethods.minW5;
        pub const minW6 = GeneratedStyledMethods.minW6;
        pub const minW7 = GeneratedStyledMethods.minW7;
        pub const minW8 = GeneratedStyledMethods.minW8;
        pub const minW9 = GeneratedStyledMethods.minW9;
        pub const minW10 = GeneratedStyledMethods.minW10;
        pub const minW11 = GeneratedStyledMethods.minW11;
        pub const minW12 = GeneratedStyledMethods.minW12;
        pub const minW16 = GeneratedStyledMethods.minW16;
        pub const minW20 = GeneratedStyledMethods.minW20;
        pub const minW24 = GeneratedStyledMethods.minW24;
        pub const minW32 = GeneratedStyledMethods.minW32;
        pub const minW40 = GeneratedStyledMethods.minW40;
        pub const minW48 = GeneratedStyledMethods.minW48;
        pub const minW56 = GeneratedStyledMethods.minW56;
        pub const minW64 = GeneratedStyledMethods.minW64;
        pub const minW72 = GeneratedStyledMethods.minW72;
        pub const minW80 = GeneratedStyledMethods.minW80;
        pub const minW96 = GeneratedStyledMethods.minW96;
        pub const minW112 = GeneratedStyledMethods.minW112;
        pub const minW128 = GeneratedStyledMethods.minW128;
        pub const minWAuto = GeneratedStyledMethods.minWAuto;
        pub const minWPx = GeneratedStyledMethods.minWPx;
        pub const minWFull = GeneratedStyledMethods.minWFull;
        pub const minW1_2 = GeneratedStyledMethods.minW1_2;
        pub const minW1_3 = GeneratedStyledMethods.minW1_3;
        pub const minW2_3 = GeneratedStyledMethods.minW2_3;
        pub const minW1_4 = GeneratedStyledMethods.minW1_4;
        pub const minW2_4 = GeneratedStyledMethods.minW2_4;
        pub const minW3_4 = GeneratedStyledMethods.minW3_4;
        pub const minW1_5 = GeneratedStyledMethods.minW1_5;
        pub const minW2_5 = GeneratedStyledMethods.minW2_5;
        pub const minW3_5 = GeneratedStyledMethods.minW3_5;
        pub const minW4_5 = GeneratedStyledMethods.minW4_5;
        pub const minW1_6 = GeneratedStyledMethods.minW1_6;
        pub const minW5_6 = GeneratedStyledMethods.minW5_6;
        pub const minW1_12 = GeneratedStyledMethods.minW1_12;
        pub const minH = GeneratedStyledMethods.minH;
        pub const minH0 = GeneratedStyledMethods.minH0;
        pub const minH0p5 = GeneratedStyledMethods.minH0p5;
        pub const minH1 = GeneratedStyledMethods.minH1;
        pub const minH1p5 = GeneratedStyledMethods.minH1p5;
        pub const minH2 = GeneratedStyledMethods.minH2;
        pub const minH2p5 = GeneratedStyledMethods.minH2p5;
        pub const minH3 = GeneratedStyledMethods.minH3;
        pub const minH3p5 = GeneratedStyledMethods.minH3p5;
        pub const minH4 = GeneratedStyledMethods.minH4;
        pub const minH5 = GeneratedStyledMethods.minH5;
        pub const minH6 = GeneratedStyledMethods.minH6;
        pub const minH7 = GeneratedStyledMethods.minH7;
        pub const minH8 = GeneratedStyledMethods.minH8;
        pub const minH9 = GeneratedStyledMethods.minH9;
        pub const minH10 = GeneratedStyledMethods.minH10;
        pub const minH11 = GeneratedStyledMethods.minH11;
        pub const minH12 = GeneratedStyledMethods.minH12;
        pub const minH16 = GeneratedStyledMethods.minH16;
        pub const minH20 = GeneratedStyledMethods.minH20;
        pub const minH24 = GeneratedStyledMethods.minH24;
        pub const minH32 = GeneratedStyledMethods.minH32;
        pub const minH40 = GeneratedStyledMethods.minH40;
        pub const minH48 = GeneratedStyledMethods.minH48;
        pub const minH56 = GeneratedStyledMethods.minH56;
        pub const minH64 = GeneratedStyledMethods.minH64;
        pub const minH72 = GeneratedStyledMethods.minH72;
        pub const minH80 = GeneratedStyledMethods.minH80;
        pub const minH96 = GeneratedStyledMethods.minH96;
        pub const minH112 = GeneratedStyledMethods.minH112;
        pub const minH128 = GeneratedStyledMethods.minH128;
        pub const minHAuto = GeneratedStyledMethods.minHAuto;
        pub const minHPx = GeneratedStyledMethods.minHPx;
        pub const minHFull = GeneratedStyledMethods.minHFull;
        pub const minH1_2 = GeneratedStyledMethods.minH1_2;
        pub const minH1_3 = GeneratedStyledMethods.minH1_3;
        pub const minH2_3 = GeneratedStyledMethods.minH2_3;
        pub const minH1_4 = GeneratedStyledMethods.minH1_4;
        pub const minH2_4 = GeneratedStyledMethods.minH2_4;
        pub const minH3_4 = GeneratedStyledMethods.minH3_4;
        pub const minH1_5 = GeneratedStyledMethods.minH1_5;
        pub const minH2_5 = GeneratedStyledMethods.minH2_5;
        pub const minH3_5 = GeneratedStyledMethods.minH3_5;
        pub const minH4_5 = GeneratedStyledMethods.minH4_5;
        pub const minH1_6 = GeneratedStyledMethods.minH1_6;
        pub const minH5_6 = GeneratedStyledMethods.minH5_6;
        pub const minH1_12 = GeneratedStyledMethods.minH1_12;
        pub const maxSize = GeneratedStyledMethods.maxSize;
        pub const maxSize0 = GeneratedStyledMethods.maxSize0;
        pub const maxSize0p5 = GeneratedStyledMethods.maxSize0p5;
        pub const maxSize1 = GeneratedStyledMethods.maxSize1;
        pub const maxSize1p5 = GeneratedStyledMethods.maxSize1p5;
        pub const maxSize2 = GeneratedStyledMethods.maxSize2;
        pub const maxSize2p5 = GeneratedStyledMethods.maxSize2p5;
        pub const maxSize3 = GeneratedStyledMethods.maxSize3;
        pub const maxSize3p5 = GeneratedStyledMethods.maxSize3p5;
        pub const maxSize4 = GeneratedStyledMethods.maxSize4;
        pub const maxSize5 = GeneratedStyledMethods.maxSize5;
        pub const maxSize6 = GeneratedStyledMethods.maxSize6;
        pub const maxSize7 = GeneratedStyledMethods.maxSize7;
        pub const maxSize8 = GeneratedStyledMethods.maxSize8;
        pub const maxSize9 = GeneratedStyledMethods.maxSize9;
        pub const maxSize10 = GeneratedStyledMethods.maxSize10;
        pub const maxSize11 = GeneratedStyledMethods.maxSize11;
        pub const maxSize12 = GeneratedStyledMethods.maxSize12;
        pub const maxSize16 = GeneratedStyledMethods.maxSize16;
        pub const maxSize20 = GeneratedStyledMethods.maxSize20;
        pub const maxSize24 = GeneratedStyledMethods.maxSize24;
        pub const maxSize32 = GeneratedStyledMethods.maxSize32;
        pub const maxSize40 = GeneratedStyledMethods.maxSize40;
        pub const maxSize48 = GeneratedStyledMethods.maxSize48;
        pub const maxSize56 = GeneratedStyledMethods.maxSize56;
        pub const maxSize64 = GeneratedStyledMethods.maxSize64;
        pub const maxSize72 = GeneratedStyledMethods.maxSize72;
        pub const maxSize80 = GeneratedStyledMethods.maxSize80;
        pub const maxSize96 = GeneratedStyledMethods.maxSize96;
        pub const maxSize112 = GeneratedStyledMethods.maxSize112;
        pub const maxSize128 = GeneratedStyledMethods.maxSize128;
        pub const maxSizeAuto = GeneratedStyledMethods.maxSizeAuto;
        pub const maxSizePx = GeneratedStyledMethods.maxSizePx;
        pub const maxSizeFull = GeneratedStyledMethods.maxSizeFull;
        pub const maxSize1_2 = GeneratedStyledMethods.maxSize1_2;
        pub const maxSize1_3 = GeneratedStyledMethods.maxSize1_3;
        pub const maxSize2_3 = GeneratedStyledMethods.maxSize2_3;
        pub const maxSize1_4 = GeneratedStyledMethods.maxSize1_4;
        pub const maxSize2_4 = GeneratedStyledMethods.maxSize2_4;
        pub const maxSize3_4 = GeneratedStyledMethods.maxSize3_4;
        pub const maxSize1_5 = GeneratedStyledMethods.maxSize1_5;
        pub const maxSize2_5 = GeneratedStyledMethods.maxSize2_5;
        pub const maxSize3_5 = GeneratedStyledMethods.maxSize3_5;
        pub const maxSize4_5 = GeneratedStyledMethods.maxSize4_5;
        pub const maxSize1_6 = GeneratedStyledMethods.maxSize1_6;
        pub const maxSize5_6 = GeneratedStyledMethods.maxSize5_6;
        pub const maxSize1_12 = GeneratedStyledMethods.maxSize1_12;
        pub const maxW = GeneratedStyledMethods.maxW;
        pub const maxW0 = GeneratedStyledMethods.maxW0;
        pub const maxW0p5 = GeneratedStyledMethods.maxW0p5;
        pub const maxW1 = GeneratedStyledMethods.maxW1;
        pub const maxW1p5 = GeneratedStyledMethods.maxW1p5;
        pub const maxW2 = GeneratedStyledMethods.maxW2;
        pub const maxW2p5 = GeneratedStyledMethods.maxW2p5;
        pub const maxW3 = GeneratedStyledMethods.maxW3;
        pub const maxW3p5 = GeneratedStyledMethods.maxW3p5;
        pub const maxW4 = GeneratedStyledMethods.maxW4;
        pub const maxW5 = GeneratedStyledMethods.maxW5;
        pub const maxW6 = GeneratedStyledMethods.maxW6;
        pub const maxW7 = GeneratedStyledMethods.maxW7;
        pub const maxW8 = GeneratedStyledMethods.maxW8;
        pub const maxW9 = GeneratedStyledMethods.maxW9;
        pub const maxW10 = GeneratedStyledMethods.maxW10;
        pub const maxW11 = GeneratedStyledMethods.maxW11;
        pub const maxW12 = GeneratedStyledMethods.maxW12;
        pub const maxW16 = GeneratedStyledMethods.maxW16;
        pub const maxW20 = GeneratedStyledMethods.maxW20;
        pub const maxW24 = GeneratedStyledMethods.maxW24;
        pub const maxW32 = GeneratedStyledMethods.maxW32;
        pub const maxW40 = GeneratedStyledMethods.maxW40;
        pub const maxW48 = GeneratedStyledMethods.maxW48;
        pub const maxW56 = GeneratedStyledMethods.maxW56;
        pub const maxW64 = GeneratedStyledMethods.maxW64;
        pub const maxW72 = GeneratedStyledMethods.maxW72;
        pub const maxW80 = GeneratedStyledMethods.maxW80;
        pub const maxW96 = GeneratedStyledMethods.maxW96;
        pub const maxW112 = GeneratedStyledMethods.maxW112;
        pub const maxW128 = GeneratedStyledMethods.maxW128;
        pub const maxWAuto = GeneratedStyledMethods.maxWAuto;
        pub const maxWPx = GeneratedStyledMethods.maxWPx;
        pub const maxWFull = GeneratedStyledMethods.maxWFull;
        pub const maxW1_2 = GeneratedStyledMethods.maxW1_2;
        pub const maxW1_3 = GeneratedStyledMethods.maxW1_3;
        pub const maxW2_3 = GeneratedStyledMethods.maxW2_3;
        pub const maxW1_4 = GeneratedStyledMethods.maxW1_4;
        pub const maxW2_4 = GeneratedStyledMethods.maxW2_4;
        pub const maxW3_4 = GeneratedStyledMethods.maxW3_4;
        pub const maxW1_5 = GeneratedStyledMethods.maxW1_5;
        pub const maxW2_5 = GeneratedStyledMethods.maxW2_5;
        pub const maxW3_5 = GeneratedStyledMethods.maxW3_5;
        pub const maxW4_5 = GeneratedStyledMethods.maxW4_5;
        pub const maxW1_6 = GeneratedStyledMethods.maxW1_6;
        pub const maxW5_6 = GeneratedStyledMethods.maxW5_6;
        pub const maxW1_12 = GeneratedStyledMethods.maxW1_12;
        pub const maxH = GeneratedStyledMethods.maxH;
        pub const maxH0 = GeneratedStyledMethods.maxH0;
        pub const maxH0p5 = GeneratedStyledMethods.maxH0p5;
        pub const maxH1 = GeneratedStyledMethods.maxH1;
        pub const maxH1p5 = GeneratedStyledMethods.maxH1p5;
        pub const maxH2 = GeneratedStyledMethods.maxH2;
        pub const maxH2p5 = GeneratedStyledMethods.maxH2p5;
        pub const maxH3 = GeneratedStyledMethods.maxH3;
        pub const maxH3p5 = GeneratedStyledMethods.maxH3p5;
        pub const maxH4 = GeneratedStyledMethods.maxH4;
        pub const maxH5 = GeneratedStyledMethods.maxH5;
        pub const maxH6 = GeneratedStyledMethods.maxH6;
        pub const maxH7 = GeneratedStyledMethods.maxH7;
        pub const maxH8 = GeneratedStyledMethods.maxH8;
        pub const maxH9 = GeneratedStyledMethods.maxH9;
        pub const maxH10 = GeneratedStyledMethods.maxH10;
        pub const maxH11 = GeneratedStyledMethods.maxH11;
        pub const maxH12 = GeneratedStyledMethods.maxH12;
        pub const maxH16 = GeneratedStyledMethods.maxH16;
        pub const maxH20 = GeneratedStyledMethods.maxH20;
        pub const maxH24 = GeneratedStyledMethods.maxH24;
        pub const maxH32 = GeneratedStyledMethods.maxH32;
        pub const maxH40 = GeneratedStyledMethods.maxH40;
        pub const maxH48 = GeneratedStyledMethods.maxH48;
        pub const maxH56 = GeneratedStyledMethods.maxH56;
        pub const maxH64 = GeneratedStyledMethods.maxH64;
        pub const maxH72 = GeneratedStyledMethods.maxH72;
        pub const maxH80 = GeneratedStyledMethods.maxH80;
        pub const maxH96 = GeneratedStyledMethods.maxH96;
        pub const maxH112 = GeneratedStyledMethods.maxH112;
        pub const maxH128 = GeneratedStyledMethods.maxH128;
        pub const maxHAuto = GeneratedStyledMethods.maxHAuto;
        pub const maxHPx = GeneratedStyledMethods.maxHPx;
        pub const maxHFull = GeneratedStyledMethods.maxHFull;
        pub const maxH1_2 = GeneratedStyledMethods.maxH1_2;
        pub const maxH1_3 = GeneratedStyledMethods.maxH1_3;
        pub const maxH2_3 = GeneratedStyledMethods.maxH2_3;
        pub const maxH1_4 = GeneratedStyledMethods.maxH1_4;
        pub const maxH2_4 = GeneratedStyledMethods.maxH2_4;
        pub const maxH3_4 = GeneratedStyledMethods.maxH3_4;
        pub const maxH1_5 = GeneratedStyledMethods.maxH1_5;
        pub const maxH2_5 = GeneratedStyledMethods.maxH2_5;
        pub const maxH3_5 = GeneratedStyledMethods.maxH3_5;
        pub const maxH4_5 = GeneratedStyledMethods.maxH4_5;
        pub const maxH1_6 = GeneratedStyledMethods.maxH1_6;
        pub const maxH5_6 = GeneratedStyledMethods.maxH5_6;
        pub const maxH1_12 = GeneratedStyledMethods.maxH1_12;
        pub const gap = GeneratedStyledMethods.gap;
        pub const gap0 = GeneratedStyledMethods.gap0;
        pub const gap0p5 = GeneratedStyledMethods.gap0p5;
        pub const gap1 = GeneratedStyledMethods.gap1;
        pub const gap1p5 = GeneratedStyledMethods.gap1p5;
        pub const gap2 = GeneratedStyledMethods.gap2;
        pub const gap2p5 = GeneratedStyledMethods.gap2p5;
        pub const gap3 = GeneratedStyledMethods.gap3;
        pub const gap3p5 = GeneratedStyledMethods.gap3p5;
        pub const gap4 = GeneratedStyledMethods.gap4;
        pub const gap5 = GeneratedStyledMethods.gap5;
        pub const gap6 = GeneratedStyledMethods.gap6;
        pub const gap7 = GeneratedStyledMethods.gap7;
        pub const gap8 = GeneratedStyledMethods.gap8;
        pub const gap9 = GeneratedStyledMethods.gap9;
        pub const gap10 = GeneratedStyledMethods.gap10;
        pub const gap11 = GeneratedStyledMethods.gap11;
        pub const gap12 = GeneratedStyledMethods.gap12;
        pub const gap16 = GeneratedStyledMethods.gap16;
        pub const gap20 = GeneratedStyledMethods.gap20;
        pub const gap24 = GeneratedStyledMethods.gap24;
        pub const gap32 = GeneratedStyledMethods.gap32;
        pub const gap40 = GeneratedStyledMethods.gap40;
        pub const gap48 = GeneratedStyledMethods.gap48;
        pub const gap56 = GeneratedStyledMethods.gap56;
        pub const gap64 = GeneratedStyledMethods.gap64;
        pub const gap72 = GeneratedStyledMethods.gap72;
        pub const gap80 = GeneratedStyledMethods.gap80;
        pub const gap96 = GeneratedStyledMethods.gap96;
        pub const gap112 = GeneratedStyledMethods.gap112;
        pub const gap128 = GeneratedStyledMethods.gap128;
        pub const gapPx = GeneratedStyledMethods.gapPx;
        pub const gapFull = GeneratedStyledMethods.gapFull;
        pub const gap1_2 = GeneratedStyledMethods.gap1_2;
        pub const gap1_3 = GeneratedStyledMethods.gap1_3;
        pub const gap2_3 = GeneratedStyledMethods.gap2_3;
        pub const gap1_4 = GeneratedStyledMethods.gap1_4;
        pub const gap2_4 = GeneratedStyledMethods.gap2_4;
        pub const gap3_4 = GeneratedStyledMethods.gap3_4;
        pub const gap1_5 = GeneratedStyledMethods.gap1_5;
        pub const gap2_5 = GeneratedStyledMethods.gap2_5;
        pub const gap3_5 = GeneratedStyledMethods.gap3_5;
        pub const gap4_5 = GeneratedStyledMethods.gap4_5;
        pub const gap1_6 = GeneratedStyledMethods.gap1_6;
        pub const gap5_6 = GeneratedStyledMethods.gap5_6;
        pub const gap1_12 = GeneratedStyledMethods.gap1_12;
        pub const gapX = GeneratedStyledMethods.gapX;
        pub const gapX0 = GeneratedStyledMethods.gapX0;
        pub const gapX0p5 = GeneratedStyledMethods.gapX0p5;
        pub const gapX1 = GeneratedStyledMethods.gapX1;
        pub const gapX1p5 = GeneratedStyledMethods.gapX1p5;
        pub const gapX2 = GeneratedStyledMethods.gapX2;
        pub const gapX2p5 = GeneratedStyledMethods.gapX2p5;
        pub const gapX3 = GeneratedStyledMethods.gapX3;
        pub const gapX3p5 = GeneratedStyledMethods.gapX3p5;
        pub const gapX4 = GeneratedStyledMethods.gapX4;
        pub const gapX5 = GeneratedStyledMethods.gapX5;
        pub const gapX6 = GeneratedStyledMethods.gapX6;
        pub const gapX7 = GeneratedStyledMethods.gapX7;
        pub const gapX8 = GeneratedStyledMethods.gapX8;
        pub const gapX9 = GeneratedStyledMethods.gapX9;
        pub const gapX10 = GeneratedStyledMethods.gapX10;
        pub const gapX11 = GeneratedStyledMethods.gapX11;
        pub const gapX12 = GeneratedStyledMethods.gapX12;
        pub const gapX16 = GeneratedStyledMethods.gapX16;
        pub const gapX20 = GeneratedStyledMethods.gapX20;
        pub const gapX24 = GeneratedStyledMethods.gapX24;
        pub const gapX32 = GeneratedStyledMethods.gapX32;
        pub const gapX40 = GeneratedStyledMethods.gapX40;
        pub const gapX48 = GeneratedStyledMethods.gapX48;
        pub const gapX56 = GeneratedStyledMethods.gapX56;
        pub const gapX64 = GeneratedStyledMethods.gapX64;
        pub const gapX72 = GeneratedStyledMethods.gapX72;
        pub const gapX80 = GeneratedStyledMethods.gapX80;
        pub const gapX96 = GeneratedStyledMethods.gapX96;
        pub const gapX112 = GeneratedStyledMethods.gapX112;
        pub const gapX128 = GeneratedStyledMethods.gapX128;
        pub const gapXPx = GeneratedStyledMethods.gapXPx;
        pub const gapXFull = GeneratedStyledMethods.gapXFull;
        pub const gapX1_2 = GeneratedStyledMethods.gapX1_2;
        pub const gapX1_3 = GeneratedStyledMethods.gapX1_3;
        pub const gapX2_3 = GeneratedStyledMethods.gapX2_3;
        pub const gapX1_4 = GeneratedStyledMethods.gapX1_4;
        pub const gapX2_4 = GeneratedStyledMethods.gapX2_4;
        pub const gapX3_4 = GeneratedStyledMethods.gapX3_4;
        pub const gapX1_5 = GeneratedStyledMethods.gapX1_5;
        pub const gapX2_5 = GeneratedStyledMethods.gapX2_5;
        pub const gapX3_5 = GeneratedStyledMethods.gapX3_5;
        pub const gapX4_5 = GeneratedStyledMethods.gapX4_5;
        pub const gapX1_6 = GeneratedStyledMethods.gapX1_6;
        pub const gapX5_6 = GeneratedStyledMethods.gapX5_6;
        pub const gapX1_12 = GeneratedStyledMethods.gapX1_12;
        pub const gapY = GeneratedStyledMethods.gapY;
        pub const gapY0 = GeneratedStyledMethods.gapY0;
        pub const gapY0p5 = GeneratedStyledMethods.gapY0p5;
        pub const gapY1 = GeneratedStyledMethods.gapY1;
        pub const gapY1p5 = GeneratedStyledMethods.gapY1p5;
        pub const gapY2 = GeneratedStyledMethods.gapY2;
        pub const gapY2p5 = GeneratedStyledMethods.gapY2p5;
        pub const gapY3 = GeneratedStyledMethods.gapY3;
        pub const gapY3p5 = GeneratedStyledMethods.gapY3p5;
        pub const gapY4 = GeneratedStyledMethods.gapY4;
        pub const gapY5 = GeneratedStyledMethods.gapY5;
        pub const gapY6 = GeneratedStyledMethods.gapY6;
        pub const gapY7 = GeneratedStyledMethods.gapY7;
        pub const gapY8 = GeneratedStyledMethods.gapY8;
        pub const gapY9 = GeneratedStyledMethods.gapY9;
        pub const gapY10 = GeneratedStyledMethods.gapY10;
        pub const gapY11 = GeneratedStyledMethods.gapY11;
        pub const gapY12 = GeneratedStyledMethods.gapY12;
        pub const gapY16 = GeneratedStyledMethods.gapY16;
        pub const gapY20 = GeneratedStyledMethods.gapY20;
        pub const gapY24 = GeneratedStyledMethods.gapY24;
        pub const gapY32 = GeneratedStyledMethods.gapY32;
        pub const gapY40 = GeneratedStyledMethods.gapY40;
        pub const gapY48 = GeneratedStyledMethods.gapY48;
        pub const gapY56 = GeneratedStyledMethods.gapY56;
        pub const gapY64 = GeneratedStyledMethods.gapY64;
        pub const gapY72 = GeneratedStyledMethods.gapY72;
        pub const gapY80 = GeneratedStyledMethods.gapY80;
        pub const gapY96 = GeneratedStyledMethods.gapY96;
        pub const gapY112 = GeneratedStyledMethods.gapY112;
        pub const gapY128 = GeneratedStyledMethods.gapY128;
        pub const gapYPx = GeneratedStyledMethods.gapYPx;
        pub const gapYFull = GeneratedStyledMethods.gapYFull;
        pub const gapY1_2 = GeneratedStyledMethods.gapY1_2;
        pub const gapY1_3 = GeneratedStyledMethods.gapY1_3;
        pub const gapY2_3 = GeneratedStyledMethods.gapY2_3;
        pub const gapY1_4 = GeneratedStyledMethods.gapY1_4;
        pub const gapY2_4 = GeneratedStyledMethods.gapY2_4;
        pub const gapY3_4 = GeneratedStyledMethods.gapY3_4;
        pub const gapY1_5 = GeneratedStyledMethods.gapY1_5;
        pub const gapY2_5 = GeneratedStyledMethods.gapY2_5;
        pub const gapY3_5 = GeneratedStyledMethods.gapY3_5;
        pub const gapY4_5 = GeneratedStyledMethods.gapY4_5;
        pub const gapY1_6 = GeneratedStyledMethods.gapY1_6;
        pub const gapY5_6 = GeneratedStyledMethods.gapY5_6;
        pub const gapY1_12 = GeneratedStyledMethods.gapY1_12;
        pub const m = GeneratedStyledMethods.m;
        pub const m0 = GeneratedStyledMethods.m0;
        pub const mNeg0 = GeneratedStyledMethods.mNeg0;
        pub const m0p5 = GeneratedStyledMethods.m0p5;
        pub const mNeg0p5 = GeneratedStyledMethods.mNeg0p5;
        pub const m1 = GeneratedStyledMethods.m1;
        pub const mNeg1 = GeneratedStyledMethods.mNeg1;
        pub const m1p5 = GeneratedStyledMethods.m1p5;
        pub const mNeg1p5 = GeneratedStyledMethods.mNeg1p5;
        pub const m2 = GeneratedStyledMethods.m2;
        pub const mNeg2 = GeneratedStyledMethods.mNeg2;
        pub const m2p5 = GeneratedStyledMethods.m2p5;
        pub const mNeg2p5 = GeneratedStyledMethods.mNeg2p5;
        pub const m3 = GeneratedStyledMethods.m3;
        pub const mNeg3 = GeneratedStyledMethods.mNeg3;
        pub const m3p5 = GeneratedStyledMethods.m3p5;
        pub const mNeg3p5 = GeneratedStyledMethods.mNeg3p5;
        pub const m4 = GeneratedStyledMethods.m4;
        pub const mNeg4 = GeneratedStyledMethods.mNeg4;
        pub const m5 = GeneratedStyledMethods.m5;
        pub const mNeg5 = GeneratedStyledMethods.mNeg5;
        pub const m6 = GeneratedStyledMethods.m6;
        pub const mNeg6 = GeneratedStyledMethods.mNeg6;
        pub const m7 = GeneratedStyledMethods.m7;
        pub const mNeg7 = GeneratedStyledMethods.mNeg7;
        pub const m8 = GeneratedStyledMethods.m8;
        pub const mNeg8 = GeneratedStyledMethods.mNeg8;
        pub const m9 = GeneratedStyledMethods.m9;
        pub const mNeg9 = GeneratedStyledMethods.mNeg9;
        pub const m10 = GeneratedStyledMethods.m10;
        pub const mNeg10 = GeneratedStyledMethods.mNeg10;
        pub const m11 = GeneratedStyledMethods.m11;
        pub const mNeg11 = GeneratedStyledMethods.mNeg11;
        pub const m12 = GeneratedStyledMethods.m12;
        pub const mNeg12 = GeneratedStyledMethods.mNeg12;
        pub const m16 = GeneratedStyledMethods.m16;
        pub const mNeg16 = GeneratedStyledMethods.mNeg16;
        pub const m20 = GeneratedStyledMethods.m20;
        pub const mNeg20 = GeneratedStyledMethods.mNeg20;
        pub const m24 = GeneratedStyledMethods.m24;
        pub const mNeg24 = GeneratedStyledMethods.mNeg24;
        pub const m32 = GeneratedStyledMethods.m32;
        pub const mNeg32 = GeneratedStyledMethods.mNeg32;
        pub const m40 = GeneratedStyledMethods.m40;
        pub const mNeg40 = GeneratedStyledMethods.mNeg40;
        pub const m48 = GeneratedStyledMethods.m48;
        pub const mNeg48 = GeneratedStyledMethods.mNeg48;
        pub const m56 = GeneratedStyledMethods.m56;
        pub const mNeg56 = GeneratedStyledMethods.mNeg56;
        pub const m64 = GeneratedStyledMethods.m64;
        pub const mNeg64 = GeneratedStyledMethods.mNeg64;
        pub const m72 = GeneratedStyledMethods.m72;
        pub const mNeg72 = GeneratedStyledMethods.mNeg72;
        pub const m80 = GeneratedStyledMethods.m80;
        pub const mNeg80 = GeneratedStyledMethods.mNeg80;
        pub const m96 = GeneratedStyledMethods.m96;
        pub const mNeg96 = GeneratedStyledMethods.mNeg96;
        pub const m112 = GeneratedStyledMethods.m112;
        pub const mNeg112 = GeneratedStyledMethods.mNeg112;
        pub const m128 = GeneratedStyledMethods.m128;
        pub const mNeg128 = GeneratedStyledMethods.mNeg128;
        pub const mAuto = GeneratedStyledMethods.mAuto;
        pub const mPx = GeneratedStyledMethods.mPx;
        pub const mNegPx = GeneratedStyledMethods.mNegPx;
        pub const mFull = GeneratedStyledMethods.mFull;
        pub const mNegFull = GeneratedStyledMethods.mNegFull;
        pub const m1_2 = GeneratedStyledMethods.m1_2;
        pub const mNeg1_2 = GeneratedStyledMethods.mNeg1_2;
        pub const m1_3 = GeneratedStyledMethods.m1_3;
        pub const mNeg1_3 = GeneratedStyledMethods.mNeg1_3;
        pub const m2_3 = GeneratedStyledMethods.m2_3;
        pub const mNeg2_3 = GeneratedStyledMethods.mNeg2_3;
        pub const m1_4 = GeneratedStyledMethods.m1_4;
        pub const mNeg1_4 = GeneratedStyledMethods.mNeg1_4;
        pub const m2_4 = GeneratedStyledMethods.m2_4;
        pub const mNeg2_4 = GeneratedStyledMethods.mNeg2_4;
        pub const m3_4 = GeneratedStyledMethods.m3_4;
        pub const mNeg3_4 = GeneratedStyledMethods.mNeg3_4;
        pub const m1_5 = GeneratedStyledMethods.m1_5;
        pub const mNeg1_5 = GeneratedStyledMethods.mNeg1_5;
        pub const m2_5 = GeneratedStyledMethods.m2_5;
        pub const mNeg2_5 = GeneratedStyledMethods.mNeg2_5;
        pub const m3_5 = GeneratedStyledMethods.m3_5;
        pub const mNeg3_5 = GeneratedStyledMethods.mNeg3_5;
        pub const m4_5 = GeneratedStyledMethods.m4_5;
        pub const mNeg4_5 = GeneratedStyledMethods.mNeg4_5;
        pub const m1_6 = GeneratedStyledMethods.m1_6;
        pub const mNeg1_6 = GeneratedStyledMethods.mNeg1_6;
        pub const m5_6 = GeneratedStyledMethods.m5_6;
        pub const mNeg5_6 = GeneratedStyledMethods.mNeg5_6;
        pub const m1_12 = GeneratedStyledMethods.m1_12;
        pub const mNeg1_12 = GeneratedStyledMethods.mNeg1_12;
        pub const mt = GeneratedStyledMethods.mt;
        pub const mt0 = GeneratedStyledMethods.mt0;
        pub const mtNeg0 = GeneratedStyledMethods.mtNeg0;
        pub const mt0p5 = GeneratedStyledMethods.mt0p5;
        pub const mtNeg0p5 = GeneratedStyledMethods.mtNeg0p5;
        pub const mt1 = GeneratedStyledMethods.mt1;
        pub const mtNeg1 = GeneratedStyledMethods.mtNeg1;
        pub const mt1p5 = GeneratedStyledMethods.mt1p5;
        pub const mtNeg1p5 = GeneratedStyledMethods.mtNeg1p5;
        pub const mt2 = GeneratedStyledMethods.mt2;
        pub const mtNeg2 = GeneratedStyledMethods.mtNeg2;
        pub const mt2p5 = GeneratedStyledMethods.mt2p5;
        pub const mtNeg2p5 = GeneratedStyledMethods.mtNeg2p5;
        pub const mt3 = GeneratedStyledMethods.mt3;
        pub const mtNeg3 = GeneratedStyledMethods.mtNeg3;
        pub const mt3p5 = GeneratedStyledMethods.mt3p5;
        pub const mtNeg3p5 = GeneratedStyledMethods.mtNeg3p5;
        pub const mt4 = GeneratedStyledMethods.mt4;
        pub const mtNeg4 = GeneratedStyledMethods.mtNeg4;
        pub const mt5 = GeneratedStyledMethods.mt5;
        pub const mtNeg5 = GeneratedStyledMethods.mtNeg5;
        pub const mt6 = GeneratedStyledMethods.mt6;
        pub const mtNeg6 = GeneratedStyledMethods.mtNeg6;
        pub const mt7 = GeneratedStyledMethods.mt7;
        pub const mtNeg7 = GeneratedStyledMethods.mtNeg7;
        pub const mt8 = GeneratedStyledMethods.mt8;
        pub const mtNeg8 = GeneratedStyledMethods.mtNeg8;
        pub const mt9 = GeneratedStyledMethods.mt9;
        pub const mtNeg9 = GeneratedStyledMethods.mtNeg9;
        pub const mt10 = GeneratedStyledMethods.mt10;
        pub const mtNeg10 = GeneratedStyledMethods.mtNeg10;
        pub const mt11 = GeneratedStyledMethods.mt11;
        pub const mtNeg11 = GeneratedStyledMethods.mtNeg11;
        pub const mt12 = GeneratedStyledMethods.mt12;
        pub const mtNeg12 = GeneratedStyledMethods.mtNeg12;
        pub const mt16 = GeneratedStyledMethods.mt16;
        pub const mtNeg16 = GeneratedStyledMethods.mtNeg16;
        pub const mt20 = GeneratedStyledMethods.mt20;
        pub const mtNeg20 = GeneratedStyledMethods.mtNeg20;
        pub const mt24 = GeneratedStyledMethods.mt24;
        pub const mtNeg24 = GeneratedStyledMethods.mtNeg24;
        pub const mt32 = GeneratedStyledMethods.mt32;
        pub const mtNeg32 = GeneratedStyledMethods.mtNeg32;
        pub const mt40 = GeneratedStyledMethods.mt40;
        pub const mtNeg40 = GeneratedStyledMethods.mtNeg40;
        pub const mt48 = GeneratedStyledMethods.mt48;
        pub const mtNeg48 = GeneratedStyledMethods.mtNeg48;
        pub const mt56 = GeneratedStyledMethods.mt56;
        pub const mtNeg56 = GeneratedStyledMethods.mtNeg56;
        pub const mt64 = GeneratedStyledMethods.mt64;
        pub const mtNeg64 = GeneratedStyledMethods.mtNeg64;
        pub const mt72 = GeneratedStyledMethods.mt72;
        pub const mtNeg72 = GeneratedStyledMethods.mtNeg72;
        pub const mt80 = GeneratedStyledMethods.mt80;
        pub const mtNeg80 = GeneratedStyledMethods.mtNeg80;
        pub const mt96 = GeneratedStyledMethods.mt96;
        pub const mtNeg96 = GeneratedStyledMethods.mtNeg96;
        pub const mt112 = GeneratedStyledMethods.mt112;
        pub const mtNeg112 = GeneratedStyledMethods.mtNeg112;
        pub const mt128 = GeneratedStyledMethods.mt128;
        pub const mtNeg128 = GeneratedStyledMethods.mtNeg128;
        pub const mtAuto = GeneratedStyledMethods.mtAuto;
        pub const mtPx = GeneratedStyledMethods.mtPx;
        pub const mtNegPx = GeneratedStyledMethods.mtNegPx;
        pub const mtFull = GeneratedStyledMethods.mtFull;
        pub const mtNegFull = GeneratedStyledMethods.mtNegFull;
        pub const mt1_2 = GeneratedStyledMethods.mt1_2;
        pub const mtNeg1_2 = GeneratedStyledMethods.mtNeg1_2;
        pub const mt1_3 = GeneratedStyledMethods.mt1_3;
        pub const mtNeg1_3 = GeneratedStyledMethods.mtNeg1_3;
        pub const mt2_3 = GeneratedStyledMethods.mt2_3;
        pub const mtNeg2_3 = GeneratedStyledMethods.mtNeg2_3;
        pub const mt1_4 = GeneratedStyledMethods.mt1_4;
        pub const mtNeg1_4 = GeneratedStyledMethods.mtNeg1_4;
        pub const mt2_4 = GeneratedStyledMethods.mt2_4;
        pub const mtNeg2_4 = GeneratedStyledMethods.mtNeg2_4;
        pub const mt3_4 = GeneratedStyledMethods.mt3_4;
        pub const mtNeg3_4 = GeneratedStyledMethods.mtNeg3_4;
        pub const mt1_5 = GeneratedStyledMethods.mt1_5;
        pub const mtNeg1_5 = GeneratedStyledMethods.mtNeg1_5;
        pub const mt2_5 = GeneratedStyledMethods.mt2_5;
        pub const mtNeg2_5 = GeneratedStyledMethods.mtNeg2_5;
        pub const mt3_5 = GeneratedStyledMethods.mt3_5;
        pub const mtNeg3_5 = GeneratedStyledMethods.mtNeg3_5;
        pub const mt4_5 = GeneratedStyledMethods.mt4_5;
        pub const mtNeg4_5 = GeneratedStyledMethods.mtNeg4_5;
        pub const mt1_6 = GeneratedStyledMethods.mt1_6;
        pub const mtNeg1_6 = GeneratedStyledMethods.mtNeg1_6;
        pub const mt5_6 = GeneratedStyledMethods.mt5_6;
        pub const mtNeg5_6 = GeneratedStyledMethods.mtNeg5_6;
        pub const mt1_12 = GeneratedStyledMethods.mt1_12;
        pub const mtNeg1_12 = GeneratedStyledMethods.mtNeg1_12;
        pub const mb = GeneratedStyledMethods.mb;
        pub const mb0 = GeneratedStyledMethods.mb0;
        pub const mbNeg0 = GeneratedStyledMethods.mbNeg0;
        pub const mb0p5 = GeneratedStyledMethods.mb0p5;
        pub const mbNeg0p5 = GeneratedStyledMethods.mbNeg0p5;
        pub const mb1 = GeneratedStyledMethods.mb1;
        pub const mbNeg1 = GeneratedStyledMethods.mbNeg1;
        pub const mb1p5 = GeneratedStyledMethods.mb1p5;
        pub const mbNeg1p5 = GeneratedStyledMethods.mbNeg1p5;
        pub const mb2 = GeneratedStyledMethods.mb2;
        pub const mbNeg2 = GeneratedStyledMethods.mbNeg2;
        pub const mb2p5 = GeneratedStyledMethods.mb2p5;
        pub const mbNeg2p5 = GeneratedStyledMethods.mbNeg2p5;
        pub const mb3 = GeneratedStyledMethods.mb3;
        pub const mbNeg3 = GeneratedStyledMethods.mbNeg3;
        pub const mb3p5 = GeneratedStyledMethods.mb3p5;
        pub const mbNeg3p5 = GeneratedStyledMethods.mbNeg3p5;
        pub const mb4 = GeneratedStyledMethods.mb4;
        pub const mbNeg4 = GeneratedStyledMethods.mbNeg4;
        pub const mb5 = GeneratedStyledMethods.mb5;
        pub const mbNeg5 = GeneratedStyledMethods.mbNeg5;
        pub const mb6 = GeneratedStyledMethods.mb6;
        pub const mbNeg6 = GeneratedStyledMethods.mbNeg6;
        pub const mb7 = GeneratedStyledMethods.mb7;
        pub const mbNeg7 = GeneratedStyledMethods.mbNeg7;
        pub const mb8 = GeneratedStyledMethods.mb8;
        pub const mbNeg8 = GeneratedStyledMethods.mbNeg8;
        pub const mb9 = GeneratedStyledMethods.mb9;
        pub const mbNeg9 = GeneratedStyledMethods.mbNeg9;
        pub const mb10 = GeneratedStyledMethods.mb10;
        pub const mbNeg10 = GeneratedStyledMethods.mbNeg10;
        pub const mb11 = GeneratedStyledMethods.mb11;
        pub const mbNeg11 = GeneratedStyledMethods.mbNeg11;
        pub const mb12 = GeneratedStyledMethods.mb12;
        pub const mbNeg12 = GeneratedStyledMethods.mbNeg12;
        pub const mb16 = GeneratedStyledMethods.mb16;
        pub const mbNeg16 = GeneratedStyledMethods.mbNeg16;
        pub const mb20 = GeneratedStyledMethods.mb20;
        pub const mbNeg20 = GeneratedStyledMethods.mbNeg20;
        pub const mb24 = GeneratedStyledMethods.mb24;
        pub const mbNeg24 = GeneratedStyledMethods.mbNeg24;
        pub const mb32 = GeneratedStyledMethods.mb32;
        pub const mbNeg32 = GeneratedStyledMethods.mbNeg32;
        pub const mb40 = GeneratedStyledMethods.mb40;
        pub const mbNeg40 = GeneratedStyledMethods.mbNeg40;
        pub const mb48 = GeneratedStyledMethods.mb48;
        pub const mbNeg48 = GeneratedStyledMethods.mbNeg48;
        pub const mb56 = GeneratedStyledMethods.mb56;
        pub const mbNeg56 = GeneratedStyledMethods.mbNeg56;
        pub const mb64 = GeneratedStyledMethods.mb64;
        pub const mbNeg64 = GeneratedStyledMethods.mbNeg64;
        pub const mb72 = GeneratedStyledMethods.mb72;
        pub const mbNeg72 = GeneratedStyledMethods.mbNeg72;
        pub const mb80 = GeneratedStyledMethods.mb80;
        pub const mbNeg80 = GeneratedStyledMethods.mbNeg80;
        pub const mb96 = GeneratedStyledMethods.mb96;
        pub const mbNeg96 = GeneratedStyledMethods.mbNeg96;
        pub const mb112 = GeneratedStyledMethods.mb112;
        pub const mbNeg112 = GeneratedStyledMethods.mbNeg112;
        pub const mb128 = GeneratedStyledMethods.mb128;
        pub const mbNeg128 = GeneratedStyledMethods.mbNeg128;
        pub const mbAuto = GeneratedStyledMethods.mbAuto;
        pub const mbPx = GeneratedStyledMethods.mbPx;
        pub const mbNegPx = GeneratedStyledMethods.mbNegPx;
        pub const mbFull = GeneratedStyledMethods.mbFull;
        pub const mbNegFull = GeneratedStyledMethods.mbNegFull;
        pub const mb1_2 = GeneratedStyledMethods.mb1_2;
        pub const mbNeg1_2 = GeneratedStyledMethods.mbNeg1_2;
        pub const mb1_3 = GeneratedStyledMethods.mb1_3;
        pub const mbNeg1_3 = GeneratedStyledMethods.mbNeg1_3;
        pub const mb2_3 = GeneratedStyledMethods.mb2_3;
        pub const mbNeg2_3 = GeneratedStyledMethods.mbNeg2_3;
        pub const mb1_4 = GeneratedStyledMethods.mb1_4;
        pub const mbNeg1_4 = GeneratedStyledMethods.mbNeg1_4;
        pub const mb2_4 = GeneratedStyledMethods.mb2_4;
        pub const mbNeg2_4 = GeneratedStyledMethods.mbNeg2_4;
        pub const mb3_4 = GeneratedStyledMethods.mb3_4;
        pub const mbNeg3_4 = GeneratedStyledMethods.mbNeg3_4;
        pub const mb1_5 = GeneratedStyledMethods.mb1_5;
        pub const mbNeg1_5 = GeneratedStyledMethods.mbNeg1_5;
        pub const mb2_5 = GeneratedStyledMethods.mb2_5;
        pub const mbNeg2_5 = GeneratedStyledMethods.mbNeg2_5;
        pub const mb3_5 = GeneratedStyledMethods.mb3_5;
        pub const mbNeg3_5 = GeneratedStyledMethods.mbNeg3_5;
        pub const mb4_5 = GeneratedStyledMethods.mb4_5;
        pub const mbNeg4_5 = GeneratedStyledMethods.mbNeg4_5;
        pub const mb1_6 = GeneratedStyledMethods.mb1_6;
        pub const mbNeg1_6 = GeneratedStyledMethods.mbNeg1_6;
        pub const mb5_6 = GeneratedStyledMethods.mb5_6;
        pub const mbNeg5_6 = GeneratedStyledMethods.mbNeg5_6;
        pub const mb1_12 = GeneratedStyledMethods.mb1_12;
        pub const mbNeg1_12 = GeneratedStyledMethods.mbNeg1_12;
        pub const my = GeneratedStyledMethods.my;
        pub const my0 = GeneratedStyledMethods.my0;
        pub const myNeg0 = GeneratedStyledMethods.myNeg0;
        pub const my0p5 = GeneratedStyledMethods.my0p5;
        pub const myNeg0p5 = GeneratedStyledMethods.myNeg0p5;
        pub const my1 = GeneratedStyledMethods.my1;
        pub const myNeg1 = GeneratedStyledMethods.myNeg1;
        pub const my1p5 = GeneratedStyledMethods.my1p5;
        pub const myNeg1p5 = GeneratedStyledMethods.myNeg1p5;
        pub const my2 = GeneratedStyledMethods.my2;
        pub const myNeg2 = GeneratedStyledMethods.myNeg2;
        pub const my2p5 = GeneratedStyledMethods.my2p5;
        pub const myNeg2p5 = GeneratedStyledMethods.myNeg2p5;
        pub const my3 = GeneratedStyledMethods.my3;
        pub const myNeg3 = GeneratedStyledMethods.myNeg3;
        pub const my3p5 = GeneratedStyledMethods.my3p5;
        pub const myNeg3p5 = GeneratedStyledMethods.myNeg3p5;
        pub const my4 = GeneratedStyledMethods.my4;
        pub const myNeg4 = GeneratedStyledMethods.myNeg4;
        pub const my5 = GeneratedStyledMethods.my5;
        pub const myNeg5 = GeneratedStyledMethods.myNeg5;
        pub const my6 = GeneratedStyledMethods.my6;
        pub const myNeg6 = GeneratedStyledMethods.myNeg6;
        pub const my7 = GeneratedStyledMethods.my7;
        pub const myNeg7 = GeneratedStyledMethods.myNeg7;
        pub const my8 = GeneratedStyledMethods.my8;
        pub const myNeg8 = GeneratedStyledMethods.myNeg8;
        pub const my9 = GeneratedStyledMethods.my9;
        pub const myNeg9 = GeneratedStyledMethods.myNeg9;
        pub const my10 = GeneratedStyledMethods.my10;
        pub const myNeg10 = GeneratedStyledMethods.myNeg10;
        pub const my11 = GeneratedStyledMethods.my11;
        pub const myNeg11 = GeneratedStyledMethods.myNeg11;
        pub const my12 = GeneratedStyledMethods.my12;
        pub const myNeg12 = GeneratedStyledMethods.myNeg12;
        pub const my16 = GeneratedStyledMethods.my16;
        pub const myNeg16 = GeneratedStyledMethods.myNeg16;
        pub const my20 = GeneratedStyledMethods.my20;
        pub const myNeg20 = GeneratedStyledMethods.myNeg20;
        pub const my24 = GeneratedStyledMethods.my24;
        pub const myNeg24 = GeneratedStyledMethods.myNeg24;
        pub const my32 = GeneratedStyledMethods.my32;
        pub const myNeg32 = GeneratedStyledMethods.myNeg32;
        pub const my40 = GeneratedStyledMethods.my40;
        pub const myNeg40 = GeneratedStyledMethods.myNeg40;
        pub const my48 = GeneratedStyledMethods.my48;
        pub const myNeg48 = GeneratedStyledMethods.myNeg48;
        pub const my56 = GeneratedStyledMethods.my56;
        pub const myNeg56 = GeneratedStyledMethods.myNeg56;
        pub const my64 = GeneratedStyledMethods.my64;
        pub const myNeg64 = GeneratedStyledMethods.myNeg64;
        pub const my72 = GeneratedStyledMethods.my72;
        pub const myNeg72 = GeneratedStyledMethods.myNeg72;
        pub const my80 = GeneratedStyledMethods.my80;
        pub const myNeg80 = GeneratedStyledMethods.myNeg80;
        pub const my96 = GeneratedStyledMethods.my96;
        pub const myNeg96 = GeneratedStyledMethods.myNeg96;
        pub const my112 = GeneratedStyledMethods.my112;
        pub const myNeg112 = GeneratedStyledMethods.myNeg112;
        pub const my128 = GeneratedStyledMethods.my128;
        pub const myNeg128 = GeneratedStyledMethods.myNeg128;
        pub const myAuto = GeneratedStyledMethods.myAuto;
        pub const myPx = GeneratedStyledMethods.myPx;
        pub const myNegPx = GeneratedStyledMethods.myNegPx;
        pub const myFull = GeneratedStyledMethods.myFull;
        pub const myNegFull = GeneratedStyledMethods.myNegFull;
        pub const my1_2 = GeneratedStyledMethods.my1_2;
        pub const myNeg1_2 = GeneratedStyledMethods.myNeg1_2;
        pub const my1_3 = GeneratedStyledMethods.my1_3;
        pub const myNeg1_3 = GeneratedStyledMethods.myNeg1_3;
        pub const my2_3 = GeneratedStyledMethods.my2_3;
        pub const myNeg2_3 = GeneratedStyledMethods.myNeg2_3;
        pub const my1_4 = GeneratedStyledMethods.my1_4;
        pub const myNeg1_4 = GeneratedStyledMethods.myNeg1_4;
        pub const my2_4 = GeneratedStyledMethods.my2_4;
        pub const myNeg2_4 = GeneratedStyledMethods.myNeg2_4;
        pub const my3_4 = GeneratedStyledMethods.my3_4;
        pub const myNeg3_4 = GeneratedStyledMethods.myNeg3_4;
        pub const my1_5 = GeneratedStyledMethods.my1_5;
        pub const myNeg1_5 = GeneratedStyledMethods.myNeg1_5;
        pub const my2_5 = GeneratedStyledMethods.my2_5;
        pub const myNeg2_5 = GeneratedStyledMethods.myNeg2_5;
        pub const my3_5 = GeneratedStyledMethods.my3_5;
        pub const myNeg3_5 = GeneratedStyledMethods.myNeg3_5;
        pub const my4_5 = GeneratedStyledMethods.my4_5;
        pub const myNeg4_5 = GeneratedStyledMethods.myNeg4_5;
        pub const my1_6 = GeneratedStyledMethods.my1_6;
        pub const myNeg1_6 = GeneratedStyledMethods.myNeg1_6;
        pub const my5_6 = GeneratedStyledMethods.my5_6;
        pub const myNeg5_6 = GeneratedStyledMethods.myNeg5_6;
        pub const my1_12 = GeneratedStyledMethods.my1_12;
        pub const myNeg1_12 = GeneratedStyledMethods.myNeg1_12;
        pub const mx = GeneratedStyledMethods.mx;
        pub const mx0 = GeneratedStyledMethods.mx0;
        pub const mxNeg0 = GeneratedStyledMethods.mxNeg0;
        pub const mx0p5 = GeneratedStyledMethods.mx0p5;
        pub const mxNeg0p5 = GeneratedStyledMethods.mxNeg0p5;
        pub const mx1 = GeneratedStyledMethods.mx1;
        pub const mxNeg1 = GeneratedStyledMethods.mxNeg1;
        pub const mx1p5 = GeneratedStyledMethods.mx1p5;
        pub const mxNeg1p5 = GeneratedStyledMethods.mxNeg1p5;
        pub const mx2 = GeneratedStyledMethods.mx2;
        pub const mxNeg2 = GeneratedStyledMethods.mxNeg2;
        pub const mx2p5 = GeneratedStyledMethods.mx2p5;
        pub const mxNeg2p5 = GeneratedStyledMethods.mxNeg2p5;
        pub const mx3 = GeneratedStyledMethods.mx3;
        pub const mxNeg3 = GeneratedStyledMethods.mxNeg3;
        pub const mx3p5 = GeneratedStyledMethods.mx3p5;
        pub const mxNeg3p5 = GeneratedStyledMethods.mxNeg3p5;
        pub const mx4 = GeneratedStyledMethods.mx4;
        pub const mxNeg4 = GeneratedStyledMethods.mxNeg4;
        pub const mx5 = GeneratedStyledMethods.mx5;
        pub const mxNeg5 = GeneratedStyledMethods.mxNeg5;
        pub const mx6 = GeneratedStyledMethods.mx6;
        pub const mxNeg6 = GeneratedStyledMethods.mxNeg6;
        pub const mx7 = GeneratedStyledMethods.mx7;
        pub const mxNeg7 = GeneratedStyledMethods.mxNeg7;
        pub const mx8 = GeneratedStyledMethods.mx8;
        pub const mxNeg8 = GeneratedStyledMethods.mxNeg8;
        pub const mx9 = GeneratedStyledMethods.mx9;
        pub const mxNeg9 = GeneratedStyledMethods.mxNeg9;
        pub const mx10 = GeneratedStyledMethods.mx10;
        pub const mxNeg10 = GeneratedStyledMethods.mxNeg10;
        pub const mx11 = GeneratedStyledMethods.mx11;
        pub const mxNeg11 = GeneratedStyledMethods.mxNeg11;
        pub const mx12 = GeneratedStyledMethods.mx12;
        pub const mxNeg12 = GeneratedStyledMethods.mxNeg12;
        pub const mx16 = GeneratedStyledMethods.mx16;
        pub const mxNeg16 = GeneratedStyledMethods.mxNeg16;
        pub const mx20 = GeneratedStyledMethods.mx20;
        pub const mxNeg20 = GeneratedStyledMethods.mxNeg20;
        pub const mx24 = GeneratedStyledMethods.mx24;
        pub const mxNeg24 = GeneratedStyledMethods.mxNeg24;
        pub const mx32 = GeneratedStyledMethods.mx32;
        pub const mxNeg32 = GeneratedStyledMethods.mxNeg32;
        pub const mx40 = GeneratedStyledMethods.mx40;
        pub const mxNeg40 = GeneratedStyledMethods.mxNeg40;
        pub const mx48 = GeneratedStyledMethods.mx48;
        pub const mxNeg48 = GeneratedStyledMethods.mxNeg48;
        pub const mx56 = GeneratedStyledMethods.mx56;
        pub const mxNeg56 = GeneratedStyledMethods.mxNeg56;
        pub const mx64 = GeneratedStyledMethods.mx64;
        pub const mxNeg64 = GeneratedStyledMethods.mxNeg64;
        pub const mx72 = GeneratedStyledMethods.mx72;
        pub const mxNeg72 = GeneratedStyledMethods.mxNeg72;
        pub const mx80 = GeneratedStyledMethods.mx80;
        pub const mxNeg80 = GeneratedStyledMethods.mxNeg80;
        pub const mx96 = GeneratedStyledMethods.mx96;
        pub const mxNeg96 = GeneratedStyledMethods.mxNeg96;
        pub const mx112 = GeneratedStyledMethods.mx112;
        pub const mxNeg112 = GeneratedStyledMethods.mxNeg112;
        pub const mx128 = GeneratedStyledMethods.mx128;
        pub const mxNeg128 = GeneratedStyledMethods.mxNeg128;
        pub const mxAuto = GeneratedStyledMethods.mxAuto;
        pub const mxPx = GeneratedStyledMethods.mxPx;
        pub const mxNegPx = GeneratedStyledMethods.mxNegPx;
        pub const mxFull = GeneratedStyledMethods.mxFull;
        pub const mxNegFull = GeneratedStyledMethods.mxNegFull;
        pub const mx1_2 = GeneratedStyledMethods.mx1_2;
        pub const mxNeg1_2 = GeneratedStyledMethods.mxNeg1_2;
        pub const mx1_3 = GeneratedStyledMethods.mx1_3;
        pub const mxNeg1_3 = GeneratedStyledMethods.mxNeg1_3;
        pub const mx2_3 = GeneratedStyledMethods.mx2_3;
        pub const mxNeg2_3 = GeneratedStyledMethods.mxNeg2_3;
        pub const mx1_4 = GeneratedStyledMethods.mx1_4;
        pub const mxNeg1_4 = GeneratedStyledMethods.mxNeg1_4;
        pub const mx2_4 = GeneratedStyledMethods.mx2_4;
        pub const mxNeg2_4 = GeneratedStyledMethods.mxNeg2_4;
        pub const mx3_4 = GeneratedStyledMethods.mx3_4;
        pub const mxNeg3_4 = GeneratedStyledMethods.mxNeg3_4;
        pub const mx1_5 = GeneratedStyledMethods.mx1_5;
        pub const mxNeg1_5 = GeneratedStyledMethods.mxNeg1_5;
        pub const mx2_5 = GeneratedStyledMethods.mx2_5;
        pub const mxNeg2_5 = GeneratedStyledMethods.mxNeg2_5;
        pub const mx3_5 = GeneratedStyledMethods.mx3_5;
        pub const mxNeg3_5 = GeneratedStyledMethods.mxNeg3_5;
        pub const mx4_5 = GeneratedStyledMethods.mx4_5;
        pub const mxNeg4_5 = GeneratedStyledMethods.mxNeg4_5;
        pub const mx1_6 = GeneratedStyledMethods.mx1_6;
        pub const mxNeg1_6 = GeneratedStyledMethods.mxNeg1_6;
        pub const mx5_6 = GeneratedStyledMethods.mx5_6;
        pub const mxNeg5_6 = GeneratedStyledMethods.mxNeg5_6;
        pub const mx1_12 = GeneratedStyledMethods.mx1_12;
        pub const mxNeg1_12 = GeneratedStyledMethods.mxNeg1_12;
        pub const ml = GeneratedStyledMethods.ml;
        pub const ml0 = GeneratedStyledMethods.ml0;
        pub const mlNeg0 = GeneratedStyledMethods.mlNeg0;
        pub const ml0p5 = GeneratedStyledMethods.ml0p5;
        pub const mlNeg0p5 = GeneratedStyledMethods.mlNeg0p5;
        pub const ml1 = GeneratedStyledMethods.ml1;
        pub const mlNeg1 = GeneratedStyledMethods.mlNeg1;
        pub const ml1p5 = GeneratedStyledMethods.ml1p5;
        pub const mlNeg1p5 = GeneratedStyledMethods.mlNeg1p5;
        pub const ml2 = GeneratedStyledMethods.ml2;
        pub const mlNeg2 = GeneratedStyledMethods.mlNeg2;
        pub const ml2p5 = GeneratedStyledMethods.ml2p5;
        pub const mlNeg2p5 = GeneratedStyledMethods.mlNeg2p5;
        pub const ml3 = GeneratedStyledMethods.ml3;
        pub const mlNeg3 = GeneratedStyledMethods.mlNeg3;
        pub const ml3p5 = GeneratedStyledMethods.ml3p5;
        pub const mlNeg3p5 = GeneratedStyledMethods.mlNeg3p5;
        pub const ml4 = GeneratedStyledMethods.ml4;
        pub const mlNeg4 = GeneratedStyledMethods.mlNeg4;
        pub const ml5 = GeneratedStyledMethods.ml5;
        pub const mlNeg5 = GeneratedStyledMethods.mlNeg5;
        pub const ml6 = GeneratedStyledMethods.ml6;
        pub const mlNeg6 = GeneratedStyledMethods.mlNeg6;
        pub const ml7 = GeneratedStyledMethods.ml7;
        pub const mlNeg7 = GeneratedStyledMethods.mlNeg7;
        pub const ml8 = GeneratedStyledMethods.ml8;
        pub const mlNeg8 = GeneratedStyledMethods.mlNeg8;
        pub const ml9 = GeneratedStyledMethods.ml9;
        pub const mlNeg9 = GeneratedStyledMethods.mlNeg9;
        pub const ml10 = GeneratedStyledMethods.ml10;
        pub const mlNeg10 = GeneratedStyledMethods.mlNeg10;
        pub const ml11 = GeneratedStyledMethods.ml11;
        pub const mlNeg11 = GeneratedStyledMethods.mlNeg11;
        pub const ml12 = GeneratedStyledMethods.ml12;
        pub const mlNeg12 = GeneratedStyledMethods.mlNeg12;
        pub const ml16 = GeneratedStyledMethods.ml16;
        pub const mlNeg16 = GeneratedStyledMethods.mlNeg16;
        pub const ml20 = GeneratedStyledMethods.ml20;
        pub const mlNeg20 = GeneratedStyledMethods.mlNeg20;
        pub const ml24 = GeneratedStyledMethods.ml24;
        pub const mlNeg24 = GeneratedStyledMethods.mlNeg24;
        pub const ml32 = GeneratedStyledMethods.ml32;
        pub const mlNeg32 = GeneratedStyledMethods.mlNeg32;
        pub const ml40 = GeneratedStyledMethods.ml40;
        pub const mlNeg40 = GeneratedStyledMethods.mlNeg40;
        pub const ml48 = GeneratedStyledMethods.ml48;
        pub const mlNeg48 = GeneratedStyledMethods.mlNeg48;
        pub const ml56 = GeneratedStyledMethods.ml56;
        pub const mlNeg56 = GeneratedStyledMethods.mlNeg56;
        pub const ml64 = GeneratedStyledMethods.ml64;
        pub const mlNeg64 = GeneratedStyledMethods.mlNeg64;
        pub const ml72 = GeneratedStyledMethods.ml72;
        pub const mlNeg72 = GeneratedStyledMethods.mlNeg72;
        pub const ml80 = GeneratedStyledMethods.ml80;
        pub const mlNeg80 = GeneratedStyledMethods.mlNeg80;
        pub const ml96 = GeneratedStyledMethods.ml96;
        pub const mlNeg96 = GeneratedStyledMethods.mlNeg96;
        pub const ml112 = GeneratedStyledMethods.ml112;
        pub const mlNeg112 = GeneratedStyledMethods.mlNeg112;
        pub const ml128 = GeneratedStyledMethods.ml128;
        pub const mlNeg128 = GeneratedStyledMethods.mlNeg128;
        pub const mlAuto = GeneratedStyledMethods.mlAuto;
        pub const mlPx = GeneratedStyledMethods.mlPx;
        pub const mlNegPx = GeneratedStyledMethods.mlNegPx;
        pub const mlFull = GeneratedStyledMethods.mlFull;
        pub const mlNegFull = GeneratedStyledMethods.mlNegFull;
        pub const ml1_2 = GeneratedStyledMethods.ml1_2;
        pub const mlNeg1_2 = GeneratedStyledMethods.mlNeg1_2;
        pub const ml1_3 = GeneratedStyledMethods.ml1_3;
        pub const mlNeg1_3 = GeneratedStyledMethods.mlNeg1_3;
        pub const ml2_3 = GeneratedStyledMethods.ml2_3;
        pub const mlNeg2_3 = GeneratedStyledMethods.mlNeg2_3;
        pub const ml1_4 = GeneratedStyledMethods.ml1_4;
        pub const mlNeg1_4 = GeneratedStyledMethods.mlNeg1_4;
        pub const ml2_4 = GeneratedStyledMethods.ml2_4;
        pub const mlNeg2_4 = GeneratedStyledMethods.mlNeg2_4;
        pub const ml3_4 = GeneratedStyledMethods.ml3_4;
        pub const mlNeg3_4 = GeneratedStyledMethods.mlNeg3_4;
        pub const ml1_5 = GeneratedStyledMethods.ml1_5;
        pub const mlNeg1_5 = GeneratedStyledMethods.mlNeg1_5;
        pub const ml2_5 = GeneratedStyledMethods.ml2_5;
        pub const mlNeg2_5 = GeneratedStyledMethods.mlNeg2_5;
        pub const ml3_5 = GeneratedStyledMethods.ml3_5;
        pub const mlNeg3_5 = GeneratedStyledMethods.mlNeg3_5;
        pub const ml4_5 = GeneratedStyledMethods.ml4_5;
        pub const mlNeg4_5 = GeneratedStyledMethods.mlNeg4_5;
        pub const ml1_6 = GeneratedStyledMethods.ml1_6;
        pub const mlNeg1_6 = GeneratedStyledMethods.mlNeg1_6;
        pub const ml5_6 = GeneratedStyledMethods.ml5_6;
        pub const mlNeg5_6 = GeneratedStyledMethods.mlNeg5_6;
        pub const ml1_12 = GeneratedStyledMethods.ml1_12;
        pub const mlNeg1_12 = GeneratedStyledMethods.mlNeg1_12;
        pub const mr = GeneratedStyledMethods.mr;
        pub const mr0 = GeneratedStyledMethods.mr0;
        pub const mrNeg0 = GeneratedStyledMethods.mrNeg0;
        pub const mr0p5 = GeneratedStyledMethods.mr0p5;
        pub const mrNeg0p5 = GeneratedStyledMethods.mrNeg0p5;
        pub const mr1 = GeneratedStyledMethods.mr1;
        pub const mrNeg1 = GeneratedStyledMethods.mrNeg1;
        pub const mr1p5 = GeneratedStyledMethods.mr1p5;
        pub const mrNeg1p5 = GeneratedStyledMethods.mrNeg1p5;
        pub const mr2 = GeneratedStyledMethods.mr2;
        pub const mrNeg2 = GeneratedStyledMethods.mrNeg2;
        pub const mr2p5 = GeneratedStyledMethods.mr2p5;
        pub const mrNeg2p5 = GeneratedStyledMethods.mrNeg2p5;
        pub const mr3 = GeneratedStyledMethods.mr3;
        pub const mrNeg3 = GeneratedStyledMethods.mrNeg3;
        pub const mr3p5 = GeneratedStyledMethods.mr3p5;
        pub const mrNeg3p5 = GeneratedStyledMethods.mrNeg3p5;
        pub const mr4 = GeneratedStyledMethods.mr4;
        pub const mrNeg4 = GeneratedStyledMethods.mrNeg4;
        pub const mr5 = GeneratedStyledMethods.mr5;
        pub const mrNeg5 = GeneratedStyledMethods.mrNeg5;
        pub const mr6 = GeneratedStyledMethods.mr6;
        pub const mrNeg6 = GeneratedStyledMethods.mrNeg6;
        pub const mr7 = GeneratedStyledMethods.mr7;
        pub const mrNeg7 = GeneratedStyledMethods.mrNeg7;
        pub const mr8 = GeneratedStyledMethods.mr8;
        pub const mrNeg8 = GeneratedStyledMethods.mrNeg8;
        pub const mr9 = GeneratedStyledMethods.mr9;
        pub const mrNeg9 = GeneratedStyledMethods.mrNeg9;
        pub const mr10 = GeneratedStyledMethods.mr10;
        pub const mrNeg10 = GeneratedStyledMethods.mrNeg10;
        pub const mr11 = GeneratedStyledMethods.mr11;
        pub const mrNeg11 = GeneratedStyledMethods.mrNeg11;
        pub const mr12 = GeneratedStyledMethods.mr12;
        pub const mrNeg12 = GeneratedStyledMethods.mrNeg12;
        pub const mr16 = GeneratedStyledMethods.mr16;
        pub const mrNeg16 = GeneratedStyledMethods.mrNeg16;
        pub const mr20 = GeneratedStyledMethods.mr20;
        pub const mrNeg20 = GeneratedStyledMethods.mrNeg20;
        pub const mr24 = GeneratedStyledMethods.mr24;
        pub const mrNeg24 = GeneratedStyledMethods.mrNeg24;
        pub const mr32 = GeneratedStyledMethods.mr32;
        pub const mrNeg32 = GeneratedStyledMethods.mrNeg32;
        pub const mr40 = GeneratedStyledMethods.mr40;
        pub const mrNeg40 = GeneratedStyledMethods.mrNeg40;
        pub const mr48 = GeneratedStyledMethods.mr48;
        pub const mrNeg48 = GeneratedStyledMethods.mrNeg48;
        pub const mr56 = GeneratedStyledMethods.mr56;
        pub const mrNeg56 = GeneratedStyledMethods.mrNeg56;
        pub const mr64 = GeneratedStyledMethods.mr64;
        pub const mrNeg64 = GeneratedStyledMethods.mrNeg64;
        pub const mr72 = GeneratedStyledMethods.mr72;
        pub const mrNeg72 = GeneratedStyledMethods.mrNeg72;
        pub const mr80 = GeneratedStyledMethods.mr80;
        pub const mrNeg80 = GeneratedStyledMethods.mrNeg80;
        pub const mr96 = GeneratedStyledMethods.mr96;
        pub const mrNeg96 = GeneratedStyledMethods.mrNeg96;
        pub const mr112 = GeneratedStyledMethods.mr112;
        pub const mrNeg112 = GeneratedStyledMethods.mrNeg112;
        pub const mr128 = GeneratedStyledMethods.mr128;
        pub const mrNeg128 = GeneratedStyledMethods.mrNeg128;
        pub const mrAuto = GeneratedStyledMethods.mrAuto;
        pub const mrPx = GeneratedStyledMethods.mrPx;
        pub const mrNegPx = GeneratedStyledMethods.mrNegPx;
        pub const mrFull = GeneratedStyledMethods.mrFull;
        pub const mrNegFull = GeneratedStyledMethods.mrNegFull;
        pub const mr1_2 = GeneratedStyledMethods.mr1_2;
        pub const mrNeg1_2 = GeneratedStyledMethods.mrNeg1_2;
        pub const mr1_3 = GeneratedStyledMethods.mr1_3;
        pub const mrNeg1_3 = GeneratedStyledMethods.mrNeg1_3;
        pub const mr2_3 = GeneratedStyledMethods.mr2_3;
        pub const mrNeg2_3 = GeneratedStyledMethods.mrNeg2_3;
        pub const mr1_4 = GeneratedStyledMethods.mr1_4;
        pub const mrNeg1_4 = GeneratedStyledMethods.mrNeg1_4;
        pub const mr2_4 = GeneratedStyledMethods.mr2_4;
        pub const mrNeg2_4 = GeneratedStyledMethods.mrNeg2_4;
        pub const mr3_4 = GeneratedStyledMethods.mr3_4;
        pub const mrNeg3_4 = GeneratedStyledMethods.mrNeg3_4;
        pub const mr1_5 = GeneratedStyledMethods.mr1_5;
        pub const mrNeg1_5 = GeneratedStyledMethods.mrNeg1_5;
        pub const mr2_5 = GeneratedStyledMethods.mr2_5;
        pub const mrNeg2_5 = GeneratedStyledMethods.mrNeg2_5;
        pub const mr3_5 = GeneratedStyledMethods.mr3_5;
        pub const mrNeg3_5 = GeneratedStyledMethods.mrNeg3_5;
        pub const mr4_5 = GeneratedStyledMethods.mr4_5;
        pub const mrNeg4_5 = GeneratedStyledMethods.mrNeg4_5;
        pub const mr1_6 = GeneratedStyledMethods.mr1_6;
        pub const mrNeg1_6 = GeneratedStyledMethods.mrNeg1_6;
        pub const mr5_6 = GeneratedStyledMethods.mr5_6;
        pub const mrNeg5_6 = GeneratedStyledMethods.mrNeg5_6;
        pub const mr1_12 = GeneratedStyledMethods.mr1_12;
        pub const mrNeg1_12 = GeneratedStyledMethods.mrNeg1_12;
        pub const p = GeneratedStyledMethods.p;
        pub const p0 = GeneratedStyledMethods.p0;
        pub const p0p5 = GeneratedStyledMethods.p0p5;
        pub const p1 = GeneratedStyledMethods.p1;
        pub const p1p5 = GeneratedStyledMethods.p1p5;
        pub const p2 = GeneratedStyledMethods.p2;
        pub const p2p5 = GeneratedStyledMethods.p2p5;
        pub const p3 = GeneratedStyledMethods.p3;
        pub const p3p5 = GeneratedStyledMethods.p3p5;
        pub const p4 = GeneratedStyledMethods.p4;
        pub const p5 = GeneratedStyledMethods.p5;
        pub const p6 = GeneratedStyledMethods.p6;
        pub const p7 = GeneratedStyledMethods.p7;
        pub const p8 = GeneratedStyledMethods.p8;
        pub const p9 = GeneratedStyledMethods.p9;
        pub const p10 = GeneratedStyledMethods.p10;
        pub const p11 = GeneratedStyledMethods.p11;
        pub const p12 = GeneratedStyledMethods.p12;
        pub const p16 = GeneratedStyledMethods.p16;
        pub const p20 = GeneratedStyledMethods.p20;
        pub const p24 = GeneratedStyledMethods.p24;
        pub const p32 = GeneratedStyledMethods.p32;
        pub const p40 = GeneratedStyledMethods.p40;
        pub const p48 = GeneratedStyledMethods.p48;
        pub const p56 = GeneratedStyledMethods.p56;
        pub const p64 = GeneratedStyledMethods.p64;
        pub const p72 = GeneratedStyledMethods.p72;
        pub const p80 = GeneratedStyledMethods.p80;
        pub const p96 = GeneratedStyledMethods.p96;
        pub const p112 = GeneratedStyledMethods.p112;
        pub const p128 = GeneratedStyledMethods.p128;
        pub const pPx = GeneratedStyledMethods.pPx;
        pub const pFull = GeneratedStyledMethods.pFull;
        pub const p1_2 = GeneratedStyledMethods.p1_2;
        pub const p1_3 = GeneratedStyledMethods.p1_3;
        pub const p2_3 = GeneratedStyledMethods.p2_3;
        pub const p1_4 = GeneratedStyledMethods.p1_4;
        pub const p2_4 = GeneratedStyledMethods.p2_4;
        pub const p3_4 = GeneratedStyledMethods.p3_4;
        pub const p1_5 = GeneratedStyledMethods.p1_5;
        pub const p2_5 = GeneratedStyledMethods.p2_5;
        pub const p3_5 = GeneratedStyledMethods.p3_5;
        pub const p4_5 = GeneratedStyledMethods.p4_5;
        pub const p1_6 = GeneratedStyledMethods.p1_6;
        pub const p5_6 = GeneratedStyledMethods.p5_6;
        pub const p1_12 = GeneratedStyledMethods.p1_12;
        pub const pt = GeneratedStyledMethods.pt;
        pub const pt0 = GeneratedStyledMethods.pt0;
        pub const pt0p5 = GeneratedStyledMethods.pt0p5;
        pub const pt1 = GeneratedStyledMethods.pt1;
        pub const pt1p5 = GeneratedStyledMethods.pt1p5;
        pub const pt2 = GeneratedStyledMethods.pt2;
        pub const pt2p5 = GeneratedStyledMethods.pt2p5;
        pub const pt3 = GeneratedStyledMethods.pt3;
        pub const pt3p5 = GeneratedStyledMethods.pt3p5;
        pub const pt4 = GeneratedStyledMethods.pt4;
        pub const pt5 = GeneratedStyledMethods.pt5;
        pub const pt6 = GeneratedStyledMethods.pt6;
        pub const pt7 = GeneratedStyledMethods.pt7;
        pub const pt8 = GeneratedStyledMethods.pt8;
        pub const pt9 = GeneratedStyledMethods.pt9;
        pub const pt10 = GeneratedStyledMethods.pt10;
        pub const pt11 = GeneratedStyledMethods.pt11;
        pub const pt12 = GeneratedStyledMethods.pt12;
        pub const pt16 = GeneratedStyledMethods.pt16;
        pub const pt20 = GeneratedStyledMethods.pt20;
        pub const pt24 = GeneratedStyledMethods.pt24;
        pub const pt32 = GeneratedStyledMethods.pt32;
        pub const pt40 = GeneratedStyledMethods.pt40;
        pub const pt48 = GeneratedStyledMethods.pt48;
        pub const pt56 = GeneratedStyledMethods.pt56;
        pub const pt64 = GeneratedStyledMethods.pt64;
        pub const pt72 = GeneratedStyledMethods.pt72;
        pub const pt80 = GeneratedStyledMethods.pt80;
        pub const pt96 = GeneratedStyledMethods.pt96;
        pub const pt112 = GeneratedStyledMethods.pt112;
        pub const pt128 = GeneratedStyledMethods.pt128;
        pub const ptPx = GeneratedStyledMethods.ptPx;
        pub const ptFull = GeneratedStyledMethods.ptFull;
        pub const pt1_2 = GeneratedStyledMethods.pt1_2;
        pub const pt1_3 = GeneratedStyledMethods.pt1_3;
        pub const pt2_3 = GeneratedStyledMethods.pt2_3;
        pub const pt1_4 = GeneratedStyledMethods.pt1_4;
        pub const pt2_4 = GeneratedStyledMethods.pt2_4;
        pub const pt3_4 = GeneratedStyledMethods.pt3_4;
        pub const pt1_5 = GeneratedStyledMethods.pt1_5;
        pub const pt2_5 = GeneratedStyledMethods.pt2_5;
        pub const pt3_5 = GeneratedStyledMethods.pt3_5;
        pub const pt4_5 = GeneratedStyledMethods.pt4_5;
        pub const pt1_6 = GeneratedStyledMethods.pt1_6;
        pub const pt5_6 = GeneratedStyledMethods.pt5_6;
        pub const pt1_12 = GeneratedStyledMethods.pt1_12;
        pub const pb = GeneratedStyledMethods.pb;
        pub const pb0 = GeneratedStyledMethods.pb0;
        pub const pb0p5 = GeneratedStyledMethods.pb0p5;
        pub const pb1 = GeneratedStyledMethods.pb1;
        pub const pb1p5 = GeneratedStyledMethods.pb1p5;
        pub const pb2 = GeneratedStyledMethods.pb2;
        pub const pb2p5 = GeneratedStyledMethods.pb2p5;
        pub const pb3 = GeneratedStyledMethods.pb3;
        pub const pb3p5 = GeneratedStyledMethods.pb3p5;
        pub const pb4 = GeneratedStyledMethods.pb4;
        pub const pb5 = GeneratedStyledMethods.pb5;
        pub const pb6 = GeneratedStyledMethods.pb6;
        pub const pb7 = GeneratedStyledMethods.pb7;
        pub const pb8 = GeneratedStyledMethods.pb8;
        pub const pb9 = GeneratedStyledMethods.pb9;
        pub const pb10 = GeneratedStyledMethods.pb10;
        pub const pb11 = GeneratedStyledMethods.pb11;
        pub const pb12 = GeneratedStyledMethods.pb12;
        pub const pb16 = GeneratedStyledMethods.pb16;
        pub const pb20 = GeneratedStyledMethods.pb20;
        pub const pb24 = GeneratedStyledMethods.pb24;
        pub const pb32 = GeneratedStyledMethods.pb32;
        pub const pb40 = GeneratedStyledMethods.pb40;
        pub const pb48 = GeneratedStyledMethods.pb48;
        pub const pb56 = GeneratedStyledMethods.pb56;
        pub const pb64 = GeneratedStyledMethods.pb64;
        pub const pb72 = GeneratedStyledMethods.pb72;
        pub const pb80 = GeneratedStyledMethods.pb80;
        pub const pb96 = GeneratedStyledMethods.pb96;
        pub const pb112 = GeneratedStyledMethods.pb112;
        pub const pb128 = GeneratedStyledMethods.pb128;
        pub const pbPx = GeneratedStyledMethods.pbPx;
        pub const pbFull = GeneratedStyledMethods.pbFull;
        pub const pb1_2 = GeneratedStyledMethods.pb1_2;
        pub const pb1_3 = GeneratedStyledMethods.pb1_3;
        pub const pb2_3 = GeneratedStyledMethods.pb2_3;
        pub const pb1_4 = GeneratedStyledMethods.pb1_4;
        pub const pb2_4 = GeneratedStyledMethods.pb2_4;
        pub const pb3_4 = GeneratedStyledMethods.pb3_4;
        pub const pb1_5 = GeneratedStyledMethods.pb1_5;
        pub const pb2_5 = GeneratedStyledMethods.pb2_5;
        pub const pb3_5 = GeneratedStyledMethods.pb3_5;
        pub const pb4_5 = GeneratedStyledMethods.pb4_5;
        pub const pb1_6 = GeneratedStyledMethods.pb1_6;
        pub const pb5_6 = GeneratedStyledMethods.pb5_6;
        pub const pb1_12 = GeneratedStyledMethods.pb1_12;
        pub const px = GeneratedStyledMethods.px;
        pub const px0 = GeneratedStyledMethods.px0;
        pub const px0p5 = GeneratedStyledMethods.px0p5;
        pub const px1 = GeneratedStyledMethods.px1;
        pub const px1p5 = GeneratedStyledMethods.px1p5;
        pub const px2 = GeneratedStyledMethods.px2;
        pub const px2p5 = GeneratedStyledMethods.px2p5;
        pub const px3 = GeneratedStyledMethods.px3;
        pub const px3p5 = GeneratedStyledMethods.px3p5;
        pub const px4 = GeneratedStyledMethods.px4;
        pub const px5 = GeneratedStyledMethods.px5;
        pub const px6 = GeneratedStyledMethods.px6;
        pub const px7 = GeneratedStyledMethods.px7;
        pub const px8 = GeneratedStyledMethods.px8;
        pub const px9 = GeneratedStyledMethods.px9;
        pub const px10 = GeneratedStyledMethods.px10;
        pub const px11 = GeneratedStyledMethods.px11;
        pub const px12 = GeneratedStyledMethods.px12;
        pub const px16 = GeneratedStyledMethods.px16;
        pub const px20 = GeneratedStyledMethods.px20;
        pub const px24 = GeneratedStyledMethods.px24;
        pub const px32 = GeneratedStyledMethods.px32;
        pub const px40 = GeneratedStyledMethods.px40;
        pub const px48 = GeneratedStyledMethods.px48;
        pub const px56 = GeneratedStyledMethods.px56;
        pub const px64 = GeneratedStyledMethods.px64;
        pub const px72 = GeneratedStyledMethods.px72;
        pub const px80 = GeneratedStyledMethods.px80;
        pub const px96 = GeneratedStyledMethods.px96;
        pub const px112 = GeneratedStyledMethods.px112;
        pub const px128 = GeneratedStyledMethods.px128;
        pub const pxPx = GeneratedStyledMethods.pxPx;
        pub const pxFull = GeneratedStyledMethods.pxFull;
        pub const px1_2 = GeneratedStyledMethods.px1_2;
        pub const px1_3 = GeneratedStyledMethods.px1_3;
        pub const px2_3 = GeneratedStyledMethods.px2_3;
        pub const px1_4 = GeneratedStyledMethods.px1_4;
        pub const px2_4 = GeneratedStyledMethods.px2_4;
        pub const px3_4 = GeneratedStyledMethods.px3_4;
        pub const px1_5 = GeneratedStyledMethods.px1_5;
        pub const px2_5 = GeneratedStyledMethods.px2_5;
        pub const px3_5 = GeneratedStyledMethods.px3_5;
        pub const px4_5 = GeneratedStyledMethods.px4_5;
        pub const px1_6 = GeneratedStyledMethods.px1_6;
        pub const px5_6 = GeneratedStyledMethods.px5_6;
        pub const px1_12 = GeneratedStyledMethods.px1_12;
        pub const py = GeneratedStyledMethods.py;
        pub const py0 = GeneratedStyledMethods.py0;
        pub const py0p5 = GeneratedStyledMethods.py0p5;
        pub const py1 = GeneratedStyledMethods.py1;
        pub const py1p5 = GeneratedStyledMethods.py1p5;
        pub const py2 = GeneratedStyledMethods.py2;
        pub const py2p5 = GeneratedStyledMethods.py2p5;
        pub const py3 = GeneratedStyledMethods.py3;
        pub const py3p5 = GeneratedStyledMethods.py3p5;
        pub const py4 = GeneratedStyledMethods.py4;
        pub const py5 = GeneratedStyledMethods.py5;
        pub const py6 = GeneratedStyledMethods.py6;
        pub const py7 = GeneratedStyledMethods.py7;
        pub const py8 = GeneratedStyledMethods.py8;
        pub const py9 = GeneratedStyledMethods.py9;
        pub const py10 = GeneratedStyledMethods.py10;
        pub const py11 = GeneratedStyledMethods.py11;
        pub const py12 = GeneratedStyledMethods.py12;
        pub const py16 = GeneratedStyledMethods.py16;
        pub const py20 = GeneratedStyledMethods.py20;
        pub const py24 = GeneratedStyledMethods.py24;
        pub const py32 = GeneratedStyledMethods.py32;
        pub const py40 = GeneratedStyledMethods.py40;
        pub const py48 = GeneratedStyledMethods.py48;
        pub const py56 = GeneratedStyledMethods.py56;
        pub const py64 = GeneratedStyledMethods.py64;
        pub const py72 = GeneratedStyledMethods.py72;
        pub const py80 = GeneratedStyledMethods.py80;
        pub const py96 = GeneratedStyledMethods.py96;
        pub const py112 = GeneratedStyledMethods.py112;
        pub const py128 = GeneratedStyledMethods.py128;
        pub const pyPx = GeneratedStyledMethods.pyPx;
        pub const pyFull = GeneratedStyledMethods.pyFull;
        pub const py1_2 = GeneratedStyledMethods.py1_2;
        pub const py1_3 = GeneratedStyledMethods.py1_3;
        pub const py2_3 = GeneratedStyledMethods.py2_3;
        pub const py1_4 = GeneratedStyledMethods.py1_4;
        pub const py2_4 = GeneratedStyledMethods.py2_4;
        pub const py3_4 = GeneratedStyledMethods.py3_4;
        pub const py1_5 = GeneratedStyledMethods.py1_5;
        pub const py2_5 = GeneratedStyledMethods.py2_5;
        pub const py3_5 = GeneratedStyledMethods.py3_5;
        pub const py4_5 = GeneratedStyledMethods.py4_5;
        pub const py1_6 = GeneratedStyledMethods.py1_6;
        pub const py5_6 = GeneratedStyledMethods.py5_6;
        pub const py1_12 = GeneratedStyledMethods.py1_12;
        pub const pl = GeneratedStyledMethods.pl;
        pub const pl0 = GeneratedStyledMethods.pl0;
        pub const pl0p5 = GeneratedStyledMethods.pl0p5;
        pub const pl1 = GeneratedStyledMethods.pl1;
        pub const pl1p5 = GeneratedStyledMethods.pl1p5;
        pub const pl2 = GeneratedStyledMethods.pl2;
        pub const pl2p5 = GeneratedStyledMethods.pl2p5;
        pub const pl3 = GeneratedStyledMethods.pl3;
        pub const pl3p5 = GeneratedStyledMethods.pl3p5;
        pub const pl4 = GeneratedStyledMethods.pl4;
        pub const pl5 = GeneratedStyledMethods.pl5;
        pub const pl6 = GeneratedStyledMethods.pl6;
        pub const pl7 = GeneratedStyledMethods.pl7;
        pub const pl8 = GeneratedStyledMethods.pl8;
        pub const pl9 = GeneratedStyledMethods.pl9;
        pub const pl10 = GeneratedStyledMethods.pl10;
        pub const pl11 = GeneratedStyledMethods.pl11;
        pub const pl12 = GeneratedStyledMethods.pl12;
        pub const pl16 = GeneratedStyledMethods.pl16;
        pub const pl20 = GeneratedStyledMethods.pl20;
        pub const pl24 = GeneratedStyledMethods.pl24;
        pub const pl32 = GeneratedStyledMethods.pl32;
        pub const pl40 = GeneratedStyledMethods.pl40;
        pub const pl48 = GeneratedStyledMethods.pl48;
        pub const pl56 = GeneratedStyledMethods.pl56;
        pub const pl64 = GeneratedStyledMethods.pl64;
        pub const pl72 = GeneratedStyledMethods.pl72;
        pub const pl80 = GeneratedStyledMethods.pl80;
        pub const pl96 = GeneratedStyledMethods.pl96;
        pub const pl112 = GeneratedStyledMethods.pl112;
        pub const pl128 = GeneratedStyledMethods.pl128;
        pub const plPx = GeneratedStyledMethods.plPx;
        pub const plFull = GeneratedStyledMethods.plFull;
        pub const pl1_2 = GeneratedStyledMethods.pl1_2;
        pub const pl1_3 = GeneratedStyledMethods.pl1_3;
        pub const pl2_3 = GeneratedStyledMethods.pl2_3;
        pub const pl1_4 = GeneratedStyledMethods.pl1_4;
        pub const pl2_4 = GeneratedStyledMethods.pl2_4;
        pub const pl3_4 = GeneratedStyledMethods.pl3_4;
        pub const pl1_5 = GeneratedStyledMethods.pl1_5;
        pub const pl2_5 = GeneratedStyledMethods.pl2_5;
        pub const pl3_5 = GeneratedStyledMethods.pl3_5;
        pub const pl4_5 = GeneratedStyledMethods.pl4_5;
        pub const pl1_6 = GeneratedStyledMethods.pl1_6;
        pub const pl5_6 = GeneratedStyledMethods.pl5_6;
        pub const pl1_12 = GeneratedStyledMethods.pl1_12;
        pub const pr = GeneratedStyledMethods.pr;
        pub const pr0 = GeneratedStyledMethods.pr0;
        pub const pr0p5 = GeneratedStyledMethods.pr0p5;
        pub const pr1 = GeneratedStyledMethods.pr1;
        pub const pr1p5 = GeneratedStyledMethods.pr1p5;
        pub const pr2 = GeneratedStyledMethods.pr2;
        pub const pr2p5 = GeneratedStyledMethods.pr2p5;
        pub const pr3 = GeneratedStyledMethods.pr3;
        pub const pr3p5 = GeneratedStyledMethods.pr3p5;
        pub const pr4 = GeneratedStyledMethods.pr4;
        pub const pr5 = GeneratedStyledMethods.pr5;
        pub const pr6 = GeneratedStyledMethods.pr6;
        pub const pr7 = GeneratedStyledMethods.pr7;
        pub const pr8 = GeneratedStyledMethods.pr8;
        pub const pr9 = GeneratedStyledMethods.pr9;
        pub const pr10 = GeneratedStyledMethods.pr10;
        pub const pr11 = GeneratedStyledMethods.pr11;
        pub const pr12 = GeneratedStyledMethods.pr12;
        pub const pr16 = GeneratedStyledMethods.pr16;
        pub const pr20 = GeneratedStyledMethods.pr20;
        pub const pr24 = GeneratedStyledMethods.pr24;
        pub const pr32 = GeneratedStyledMethods.pr32;
        pub const pr40 = GeneratedStyledMethods.pr40;
        pub const pr48 = GeneratedStyledMethods.pr48;
        pub const pr56 = GeneratedStyledMethods.pr56;
        pub const pr64 = GeneratedStyledMethods.pr64;
        pub const pr72 = GeneratedStyledMethods.pr72;
        pub const pr80 = GeneratedStyledMethods.pr80;
        pub const pr96 = GeneratedStyledMethods.pr96;
        pub const pr112 = GeneratedStyledMethods.pr112;
        pub const pr128 = GeneratedStyledMethods.pr128;
        pub const prPx = GeneratedStyledMethods.prPx;
        pub const prFull = GeneratedStyledMethods.prFull;
        pub const pr1_2 = GeneratedStyledMethods.pr1_2;
        pub const pr1_3 = GeneratedStyledMethods.pr1_3;
        pub const pr2_3 = GeneratedStyledMethods.pr2_3;
        pub const pr1_4 = GeneratedStyledMethods.pr1_4;
        pub const pr2_4 = GeneratedStyledMethods.pr2_4;
        pub const pr3_4 = GeneratedStyledMethods.pr3_4;
        pub const pr1_5 = GeneratedStyledMethods.pr1_5;
        pub const pr2_5 = GeneratedStyledMethods.pr2_5;
        pub const pr3_5 = GeneratedStyledMethods.pr3_5;
        pub const pr4_5 = GeneratedStyledMethods.pr4_5;
        pub const pr1_6 = GeneratedStyledMethods.pr1_6;
        pub const pr5_6 = GeneratedStyledMethods.pr5_6;
        pub const pr1_12 = GeneratedStyledMethods.pr1_12;
        pub const inset = GeneratedStyledMethods.inset;
        pub const inset0 = GeneratedStyledMethods.inset0;
        pub const insetNeg0 = GeneratedStyledMethods.insetNeg0;
        pub const inset0p5 = GeneratedStyledMethods.inset0p5;
        pub const insetNeg0p5 = GeneratedStyledMethods.insetNeg0p5;
        pub const inset1 = GeneratedStyledMethods.inset1;
        pub const insetNeg1 = GeneratedStyledMethods.insetNeg1;
        pub const inset1p5 = GeneratedStyledMethods.inset1p5;
        pub const insetNeg1p5 = GeneratedStyledMethods.insetNeg1p5;
        pub const inset2 = GeneratedStyledMethods.inset2;
        pub const insetNeg2 = GeneratedStyledMethods.insetNeg2;
        pub const inset2p5 = GeneratedStyledMethods.inset2p5;
        pub const insetNeg2p5 = GeneratedStyledMethods.insetNeg2p5;
        pub const inset3 = GeneratedStyledMethods.inset3;
        pub const insetNeg3 = GeneratedStyledMethods.insetNeg3;
        pub const inset3p5 = GeneratedStyledMethods.inset3p5;
        pub const insetNeg3p5 = GeneratedStyledMethods.insetNeg3p5;
        pub const inset4 = GeneratedStyledMethods.inset4;
        pub const insetNeg4 = GeneratedStyledMethods.insetNeg4;
        pub const inset5 = GeneratedStyledMethods.inset5;
        pub const insetNeg5 = GeneratedStyledMethods.insetNeg5;
        pub const inset6 = GeneratedStyledMethods.inset6;
        pub const insetNeg6 = GeneratedStyledMethods.insetNeg6;
        pub const inset7 = GeneratedStyledMethods.inset7;
        pub const insetNeg7 = GeneratedStyledMethods.insetNeg7;
        pub const inset8 = GeneratedStyledMethods.inset8;
        pub const insetNeg8 = GeneratedStyledMethods.insetNeg8;
        pub const inset9 = GeneratedStyledMethods.inset9;
        pub const insetNeg9 = GeneratedStyledMethods.insetNeg9;
        pub const inset10 = GeneratedStyledMethods.inset10;
        pub const insetNeg10 = GeneratedStyledMethods.insetNeg10;
        pub const inset11 = GeneratedStyledMethods.inset11;
        pub const insetNeg11 = GeneratedStyledMethods.insetNeg11;
        pub const inset12 = GeneratedStyledMethods.inset12;
        pub const insetNeg12 = GeneratedStyledMethods.insetNeg12;
        pub const inset16 = GeneratedStyledMethods.inset16;
        pub const insetNeg16 = GeneratedStyledMethods.insetNeg16;
        pub const inset20 = GeneratedStyledMethods.inset20;
        pub const insetNeg20 = GeneratedStyledMethods.insetNeg20;
        pub const inset24 = GeneratedStyledMethods.inset24;
        pub const insetNeg24 = GeneratedStyledMethods.insetNeg24;
        pub const inset32 = GeneratedStyledMethods.inset32;
        pub const insetNeg32 = GeneratedStyledMethods.insetNeg32;
        pub const inset40 = GeneratedStyledMethods.inset40;
        pub const insetNeg40 = GeneratedStyledMethods.insetNeg40;
        pub const inset48 = GeneratedStyledMethods.inset48;
        pub const insetNeg48 = GeneratedStyledMethods.insetNeg48;
        pub const inset56 = GeneratedStyledMethods.inset56;
        pub const insetNeg56 = GeneratedStyledMethods.insetNeg56;
        pub const inset64 = GeneratedStyledMethods.inset64;
        pub const insetNeg64 = GeneratedStyledMethods.insetNeg64;
        pub const inset72 = GeneratedStyledMethods.inset72;
        pub const insetNeg72 = GeneratedStyledMethods.insetNeg72;
        pub const inset80 = GeneratedStyledMethods.inset80;
        pub const insetNeg80 = GeneratedStyledMethods.insetNeg80;
        pub const inset96 = GeneratedStyledMethods.inset96;
        pub const insetNeg96 = GeneratedStyledMethods.insetNeg96;
        pub const inset112 = GeneratedStyledMethods.inset112;
        pub const insetNeg112 = GeneratedStyledMethods.insetNeg112;
        pub const inset128 = GeneratedStyledMethods.inset128;
        pub const insetNeg128 = GeneratedStyledMethods.insetNeg128;
        pub const insetAuto = GeneratedStyledMethods.insetAuto;
        pub const insetPx = GeneratedStyledMethods.insetPx;
        pub const insetNegPx = GeneratedStyledMethods.insetNegPx;
        pub const insetFull = GeneratedStyledMethods.insetFull;
        pub const insetNegFull = GeneratedStyledMethods.insetNegFull;
        pub const inset1_2 = GeneratedStyledMethods.inset1_2;
        pub const insetNeg1_2 = GeneratedStyledMethods.insetNeg1_2;
        pub const inset1_3 = GeneratedStyledMethods.inset1_3;
        pub const insetNeg1_3 = GeneratedStyledMethods.insetNeg1_3;
        pub const inset2_3 = GeneratedStyledMethods.inset2_3;
        pub const insetNeg2_3 = GeneratedStyledMethods.insetNeg2_3;
        pub const inset1_4 = GeneratedStyledMethods.inset1_4;
        pub const insetNeg1_4 = GeneratedStyledMethods.insetNeg1_4;
        pub const inset2_4 = GeneratedStyledMethods.inset2_4;
        pub const insetNeg2_4 = GeneratedStyledMethods.insetNeg2_4;
        pub const inset3_4 = GeneratedStyledMethods.inset3_4;
        pub const insetNeg3_4 = GeneratedStyledMethods.insetNeg3_4;
        pub const inset1_5 = GeneratedStyledMethods.inset1_5;
        pub const insetNeg1_5 = GeneratedStyledMethods.insetNeg1_5;
        pub const inset2_5 = GeneratedStyledMethods.inset2_5;
        pub const insetNeg2_5 = GeneratedStyledMethods.insetNeg2_5;
        pub const inset3_5 = GeneratedStyledMethods.inset3_5;
        pub const insetNeg3_5 = GeneratedStyledMethods.insetNeg3_5;
        pub const inset4_5 = GeneratedStyledMethods.inset4_5;
        pub const insetNeg4_5 = GeneratedStyledMethods.insetNeg4_5;
        pub const inset1_6 = GeneratedStyledMethods.inset1_6;
        pub const insetNeg1_6 = GeneratedStyledMethods.insetNeg1_6;
        pub const inset5_6 = GeneratedStyledMethods.inset5_6;
        pub const insetNeg5_6 = GeneratedStyledMethods.insetNeg5_6;
        pub const inset1_12 = GeneratedStyledMethods.inset1_12;
        pub const insetNeg1_12 = GeneratedStyledMethods.insetNeg1_12;
        pub const top = GeneratedStyledMethods.top;
        pub const top0 = GeneratedStyledMethods.top0;
        pub const topNeg0 = GeneratedStyledMethods.topNeg0;
        pub const top0p5 = GeneratedStyledMethods.top0p5;
        pub const topNeg0p5 = GeneratedStyledMethods.topNeg0p5;
        pub const top1 = GeneratedStyledMethods.top1;
        pub const topNeg1 = GeneratedStyledMethods.topNeg1;
        pub const top1p5 = GeneratedStyledMethods.top1p5;
        pub const topNeg1p5 = GeneratedStyledMethods.topNeg1p5;
        pub const top2 = GeneratedStyledMethods.top2;
        pub const topNeg2 = GeneratedStyledMethods.topNeg2;
        pub const top2p5 = GeneratedStyledMethods.top2p5;
        pub const topNeg2p5 = GeneratedStyledMethods.topNeg2p5;
        pub const top3 = GeneratedStyledMethods.top3;
        pub const topNeg3 = GeneratedStyledMethods.topNeg3;
        pub const top3p5 = GeneratedStyledMethods.top3p5;
        pub const topNeg3p5 = GeneratedStyledMethods.topNeg3p5;
        pub const top4 = GeneratedStyledMethods.top4;
        pub const topNeg4 = GeneratedStyledMethods.topNeg4;
        pub const top5 = GeneratedStyledMethods.top5;
        pub const topNeg5 = GeneratedStyledMethods.topNeg5;
        pub const top6 = GeneratedStyledMethods.top6;
        pub const topNeg6 = GeneratedStyledMethods.topNeg6;
        pub const top7 = GeneratedStyledMethods.top7;
        pub const topNeg7 = GeneratedStyledMethods.topNeg7;
        pub const top8 = GeneratedStyledMethods.top8;
        pub const topNeg8 = GeneratedStyledMethods.topNeg8;
        pub const top9 = GeneratedStyledMethods.top9;
        pub const topNeg9 = GeneratedStyledMethods.topNeg9;
        pub const top10 = GeneratedStyledMethods.top10;
        pub const topNeg10 = GeneratedStyledMethods.topNeg10;
        pub const top11 = GeneratedStyledMethods.top11;
        pub const topNeg11 = GeneratedStyledMethods.topNeg11;
        pub const top12 = GeneratedStyledMethods.top12;
        pub const topNeg12 = GeneratedStyledMethods.topNeg12;
        pub const top16 = GeneratedStyledMethods.top16;
        pub const topNeg16 = GeneratedStyledMethods.topNeg16;
        pub const top20 = GeneratedStyledMethods.top20;
        pub const topNeg20 = GeneratedStyledMethods.topNeg20;
        pub const top24 = GeneratedStyledMethods.top24;
        pub const topNeg24 = GeneratedStyledMethods.topNeg24;
        pub const top32 = GeneratedStyledMethods.top32;
        pub const topNeg32 = GeneratedStyledMethods.topNeg32;
        pub const top40 = GeneratedStyledMethods.top40;
        pub const topNeg40 = GeneratedStyledMethods.topNeg40;
        pub const top48 = GeneratedStyledMethods.top48;
        pub const topNeg48 = GeneratedStyledMethods.topNeg48;
        pub const top56 = GeneratedStyledMethods.top56;
        pub const topNeg56 = GeneratedStyledMethods.topNeg56;
        pub const top64 = GeneratedStyledMethods.top64;
        pub const topNeg64 = GeneratedStyledMethods.topNeg64;
        pub const top72 = GeneratedStyledMethods.top72;
        pub const topNeg72 = GeneratedStyledMethods.topNeg72;
        pub const top80 = GeneratedStyledMethods.top80;
        pub const topNeg80 = GeneratedStyledMethods.topNeg80;
        pub const top96 = GeneratedStyledMethods.top96;
        pub const topNeg96 = GeneratedStyledMethods.topNeg96;
        pub const top112 = GeneratedStyledMethods.top112;
        pub const topNeg112 = GeneratedStyledMethods.topNeg112;
        pub const top128 = GeneratedStyledMethods.top128;
        pub const topNeg128 = GeneratedStyledMethods.topNeg128;
        pub const topAuto = GeneratedStyledMethods.topAuto;
        pub const topPx = GeneratedStyledMethods.topPx;
        pub const topNegPx = GeneratedStyledMethods.topNegPx;
        pub const topFull = GeneratedStyledMethods.topFull;
        pub const topNegFull = GeneratedStyledMethods.topNegFull;
        pub const top1_2 = GeneratedStyledMethods.top1_2;
        pub const topNeg1_2 = GeneratedStyledMethods.topNeg1_2;
        pub const top1_3 = GeneratedStyledMethods.top1_3;
        pub const topNeg1_3 = GeneratedStyledMethods.topNeg1_3;
        pub const top2_3 = GeneratedStyledMethods.top2_3;
        pub const topNeg2_3 = GeneratedStyledMethods.topNeg2_3;
        pub const top1_4 = GeneratedStyledMethods.top1_4;
        pub const topNeg1_4 = GeneratedStyledMethods.topNeg1_4;
        pub const top2_4 = GeneratedStyledMethods.top2_4;
        pub const topNeg2_4 = GeneratedStyledMethods.topNeg2_4;
        pub const top3_4 = GeneratedStyledMethods.top3_4;
        pub const topNeg3_4 = GeneratedStyledMethods.topNeg3_4;
        pub const top1_5 = GeneratedStyledMethods.top1_5;
        pub const topNeg1_5 = GeneratedStyledMethods.topNeg1_5;
        pub const top2_5 = GeneratedStyledMethods.top2_5;
        pub const topNeg2_5 = GeneratedStyledMethods.topNeg2_5;
        pub const top3_5 = GeneratedStyledMethods.top3_5;
        pub const topNeg3_5 = GeneratedStyledMethods.topNeg3_5;
        pub const top4_5 = GeneratedStyledMethods.top4_5;
        pub const topNeg4_5 = GeneratedStyledMethods.topNeg4_5;
        pub const top1_6 = GeneratedStyledMethods.top1_6;
        pub const topNeg1_6 = GeneratedStyledMethods.topNeg1_6;
        pub const top5_6 = GeneratedStyledMethods.top5_6;
        pub const topNeg5_6 = GeneratedStyledMethods.topNeg5_6;
        pub const top1_12 = GeneratedStyledMethods.top1_12;
        pub const topNeg1_12 = GeneratedStyledMethods.topNeg1_12;
        pub const bottom = GeneratedStyledMethods.bottom;
        pub const bottom0 = GeneratedStyledMethods.bottom0;
        pub const bottomNeg0 = GeneratedStyledMethods.bottomNeg0;
        pub const bottom0p5 = GeneratedStyledMethods.bottom0p5;
        pub const bottomNeg0p5 = GeneratedStyledMethods.bottomNeg0p5;
        pub const bottom1 = GeneratedStyledMethods.bottom1;
        pub const bottomNeg1 = GeneratedStyledMethods.bottomNeg1;
        pub const bottom1p5 = GeneratedStyledMethods.bottom1p5;
        pub const bottomNeg1p5 = GeneratedStyledMethods.bottomNeg1p5;
        pub const bottom2 = GeneratedStyledMethods.bottom2;
        pub const bottomNeg2 = GeneratedStyledMethods.bottomNeg2;
        pub const bottom2p5 = GeneratedStyledMethods.bottom2p5;
        pub const bottomNeg2p5 = GeneratedStyledMethods.bottomNeg2p5;
        pub const bottom3 = GeneratedStyledMethods.bottom3;
        pub const bottomNeg3 = GeneratedStyledMethods.bottomNeg3;
        pub const bottom3p5 = GeneratedStyledMethods.bottom3p5;
        pub const bottomNeg3p5 = GeneratedStyledMethods.bottomNeg3p5;
        pub const bottom4 = GeneratedStyledMethods.bottom4;
        pub const bottomNeg4 = GeneratedStyledMethods.bottomNeg4;
        pub const bottom5 = GeneratedStyledMethods.bottom5;
        pub const bottomNeg5 = GeneratedStyledMethods.bottomNeg5;
        pub const bottom6 = GeneratedStyledMethods.bottom6;
        pub const bottomNeg6 = GeneratedStyledMethods.bottomNeg6;
        pub const bottom7 = GeneratedStyledMethods.bottom7;
        pub const bottomNeg7 = GeneratedStyledMethods.bottomNeg7;
        pub const bottom8 = GeneratedStyledMethods.bottom8;
        pub const bottomNeg8 = GeneratedStyledMethods.bottomNeg8;
        pub const bottom9 = GeneratedStyledMethods.bottom9;
        pub const bottomNeg9 = GeneratedStyledMethods.bottomNeg9;
        pub const bottom10 = GeneratedStyledMethods.bottom10;
        pub const bottomNeg10 = GeneratedStyledMethods.bottomNeg10;
        pub const bottom11 = GeneratedStyledMethods.bottom11;
        pub const bottomNeg11 = GeneratedStyledMethods.bottomNeg11;
        pub const bottom12 = GeneratedStyledMethods.bottom12;
        pub const bottomNeg12 = GeneratedStyledMethods.bottomNeg12;
        pub const bottom16 = GeneratedStyledMethods.bottom16;
        pub const bottomNeg16 = GeneratedStyledMethods.bottomNeg16;
        pub const bottom20 = GeneratedStyledMethods.bottom20;
        pub const bottomNeg20 = GeneratedStyledMethods.bottomNeg20;
        pub const bottom24 = GeneratedStyledMethods.bottom24;
        pub const bottomNeg24 = GeneratedStyledMethods.bottomNeg24;
        pub const bottom32 = GeneratedStyledMethods.bottom32;
        pub const bottomNeg32 = GeneratedStyledMethods.bottomNeg32;
        pub const bottom40 = GeneratedStyledMethods.bottom40;
        pub const bottomNeg40 = GeneratedStyledMethods.bottomNeg40;
        pub const bottom48 = GeneratedStyledMethods.bottom48;
        pub const bottomNeg48 = GeneratedStyledMethods.bottomNeg48;
        pub const bottom56 = GeneratedStyledMethods.bottom56;
        pub const bottomNeg56 = GeneratedStyledMethods.bottomNeg56;
        pub const bottom64 = GeneratedStyledMethods.bottom64;
        pub const bottomNeg64 = GeneratedStyledMethods.bottomNeg64;
        pub const bottom72 = GeneratedStyledMethods.bottom72;
        pub const bottomNeg72 = GeneratedStyledMethods.bottomNeg72;
        pub const bottom80 = GeneratedStyledMethods.bottom80;
        pub const bottomNeg80 = GeneratedStyledMethods.bottomNeg80;
        pub const bottom96 = GeneratedStyledMethods.bottom96;
        pub const bottomNeg96 = GeneratedStyledMethods.bottomNeg96;
        pub const bottom112 = GeneratedStyledMethods.bottom112;
        pub const bottomNeg112 = GeneratedStyledMethods.bottomNeg112;
        pub const bottom128 = GeneratedStyledMethods.bottom128;
        pub const bottomNeg128 = GeneratedStyledMethods.bottomNeg128;
        pub const bottomAuto = GeneratedStyledMethods.bottomAuto;
        pub const bottomPx = GeneratedStyledMethods.bottomPx;
        pub const bottomNegPx = GeneratedStyledMethods.bottomNegPx;
        pub const bottomFull = GeneratedStyledMethods.bottomFull;
        pub const bottomNegFull = GeneratedStyledMethods.bottomNegFull;
        pub const bottom1_2 = GeneratedStyledMethods.bottom1_2;
        pub const bottomNeg1_2 = GeneratedStyledMethods.bottomNeg1_2;
        pub const bottom1_3 = GeneratedStyledMethods.bottom1_3;
        pub const bottomNeg1_3 = GeneratedStyledMethods.bottomNeg1_3;
        pub const bottom2_3 = GeneratedStyledMethods.bottom2_3;
        pub const bottomNeg2_3 = GeneratedStyledMethods.bottomNeg2_3;
        pub const bottom1_4 = GeneratedStyledMethods.bottom1_4;
        pub const bottomNeg1_4 = GeneratedStyledMethods.bottomNeg1_4;
        pub const bottom2_4 = GeneratedStyledMethods.bottom2_4;
        pub const bottomNeg2_4 = GeneratedStyledMethods.bottomNeg2_4;
        pub const bottom3_4 = GeneratedStyledMethods.bottom3_4;
        pub const bottomNeg3_4 = GeneratedStyledMethods.bottomNeg3_4;
        pub const bottom1_5 = GeneratedStyledMethods.bottom1_5;
        pub const bottomNeg1_5 = GeneratedStyledMethods.bottomNeg1_5;
        pub const bottom2_5 = GeneratedStyledMethods.bottom2_5;
        pub const bottomNeg2_5 = GeneratedStyledMethods.bottomNeg2_5;
        pub const bottom3_5 = GeneratedStyledMethods.bottom3_5;
        pub const bottomNeg3_5 = GeneratedStyledMethods.bottomNeg3_5;
        pub const bottom4_5 = GeneratedStyledMethods.bottom4_5;
        pub const bottomNeg4_5 = GeneratedStyledMethods.bottomNeg4_5;
        pub const bottom1_6 = GeneratedStyledMethods.bottom1_6;
        pub const bottomNeg1_6 = GeneratedStyledMethods.bottomNeg1_6;
        pub const bottom5_6 = GeneratedStyledMethods.bottom5_6;
        pub const bottomNeg5_6 = GeneratedStyledMethods.bottomNeg5_6;
        pub const bottom1_12 = GeneratedStyledMethods.bottom1_12;
        pub const bottomNeg1_12 = GeneratedStyledMethods.bottomNeg1_12;
        pub const left = GeneratedStyledMethods.left;
        pub const left0 = GeneratedStyledMethods.left0;
        pub const leftNeg0 = GeneratedStyledMethods.leftNeg0;
        pub const left0p5 = GeneratedStyledMethods.left0p5;
        pub const leftNeg0p5 = GeneratedStyledMethods.leftNeg0p5;
        pub const left1 = GeneratedStyledMethods.left1;
        pub const leftNeg1 = GeneratedStyledMethods.leftNeg1;
        pub const left1p5 = GeneratedStyledMethods.left1p5;
        pub const leftNeg1p5 = GeneratedStyledMethods.leftNeg1p5;
        pub const left2 = GeneratedStyledMethods.left2;
        pub const leftNeg2 = GeneratedStyledMethods.leftNeg2;
        pub const left2p5 = GeneratedStyledMethods.left2p5;
        pub const leftNeg2p5 = GeneratedStyledMethods.leftNeg2p5;
        pub const left3 = GeneratedStyledMethods.left3;
        pub const leftNeg3 = GeneratedStyledMethods.leftNeg3;
        pub const left3p5 = GeneratedStyledMethods.left3p5;
        pub const leftNeg3p5 = GeneratedStyledMethods.leftNeg3p5;
        pub const left4 = GeneratedStyledMethods.left4;
        pub const leftNeg4 = GeneratedStyledMethods.leftNeg4;
        pub const left5 = GeneratedStyledMethods.left5;
        pub const leftNeg5 = GeneratedStyledMethods.leftNeg5;
        pub const left6 = GeneratedStyledMethods.left6;
        pub const leftNeg6 = GeneratedStyledMethods.leftNeg6;
        pub const left7 = GeneratedStyledMethods.left7;
        pub const leftNeg7 = GeneratedStyledMethods.leftNeg7;
        pub const left8 = GeneratedStyledMethods.left8;
        pub const leftNeg8 = GeneratedStyledMethods.leftNeg8;
        pub const left9 = GeneratedStyledMethods.left9;
        pub const leftNeg9 = GeneratedStyledMethods.leftNeg9;
        pub const left10 = GeneratedStyledMethods.left10;
        pub const leftNeg10 = GeneratedStyledMethods.leftNeg10;
        pub const left11 = GeneratedStyledMethods.left11;
        pub const leftNeg11 = GeneratedStyledMethods.leftNeg11;
        pub const left12 = GeneratedStyledMethods.left12;
        pub const leftNeg12 = GeneratedStyledMethods.leftNeg12;
        pub const left16 = GeneratedStyledMethods.left16;
        pub const leftNeg16 = GeneratedStyledMethods.leftNeg16;
        pub const left20 = GeneratedStyledMethods.left20;
        pub const leftNeg20 = GeneratedStyledMethods.leftNeg20;
        pub const left24 = GeneratedStyledMethods.left24;
        pub const leftNeg24 = GeneratedStyledMethods.leftNeg24;
        pub const left32 = GeneratedStyledMethods.left32;
        pub const leftNeg32 = GeneratedStyledMethods.leftNeg32;
        pub const left40 = GeneratedStyledMethods.left40;
        pub const leftNeg40 = GeneratedStyledMethods.leftNeg40;
        pub const left48 = GeneratedStyledMethods.left48;
        pub const leftNeg48 = GeneratedStyledMethods.leftNeg48;
        pub const left56 = GeneratedStyledMethods.left56;
        pub const leftNeg56 = GeneratedStyledMethods.leftNeg56;
        pub const left64 = GeneratedStyledMethods.left64;
        pub const leftNeg64 = GeneratedStyledMethods.leftNeg64;
        pub const left72 = GeneratedStyledMethods.left72;
        pub const leftNeg72 = GeneratedStyledMethods.leftNeg72;
        pub const left80 = GeneratedStyledMethods.left80;
        pub const leftNeg80 = GeneratedStyledMethods.leftNeg80;
        pub const left96 = GeneratedStyledMethods.left96;
        pub const leftNeg96 = GeneratedStyledMethods.leftNeg96;
        pub const left112 = GeneratedStyledMethods.left112;
        pub const leftNeg112 = GeneratedStyledMethods.leftNeg112;
        pub const left128 = GeneratedStyledMethods.left128;
        pub const leftNeg128 = GeneratedStyledMethods.leftNeg128;
        pub const leftAuto = GeneratedStyledMethods.leftAuto;
        pub const leftPx = GeneratedStyledMethods.leftPx;
        pub const leftNegPx = GeneratedStyledMethods.leftNegPx;
        pub const leftFull = GeneratedStyledMethods.leftFull;
        pub const leftNegFull = GeneratedStyledMethods.leftNegFull;
        pub const left1_2 = GeneratedStyledMethods.left1_2;
        pub const leftNeg1_2 = GeneratedStyledMethods.leftNeg1_2;
        pub const left1_3 = GeneratedStyledMethods.left1_3;
        pub const leftNeg1_3 = GeneratedStyledMethods.leftNeg1_3;
        pub const left2_3 = GeneratedStyledMethods.left2_3;
        pub const leftNeg2_3 = GeneratedStyledMethods.leftNeg2_3;
        pub const left1_4 = GeneratedStyledMethods.left1_4;
        pub const leftNeg1_4 = GeneratedStyledMethods.leftNeg1_4;
        pub const left2_4 = GeneratedStyledMethods.left2_4;
        pub const leftNeg2_4 = GeneratedStyledMethods.leftNeg2_4;
        pub const left3_4 = GeneratedStyledMethods.left3_4;
        pub const leftNeg3_4 = GeneratedStyledMethods.leftNeg3_4;
        pub const left1_5 = GeneratedStyledMethods.left1_5;
        pub const leftNeg1_5 = GeneratedStyledMethods.leftNeg1_5;
        pub const left2_5 = GeneratedStyledMethods.left2_5;
        pub const leftNeg2_5 = GeneratedStyledMethods.leftNeg2_5;
        pub const left3_5 = GeneratedStyledMethods.left3_5;
        pub const leftNeg3_5 = GeneratedStyledMethods.leftNeg3_5;
        pub const left4_5 = GeneratedStyledMethods.left4_5;
        pub const leftNeg4_5 = GeneratedStyledMethods.leftNeg4_5;
        pub const left1_6 = GeneratedStyledMethods.left1_6;
        pub const leftNeg1_6 = GeneratedStyledMethods.leftNeg1_6;
        pub const left5_6 = GeneratedStyledMethods.left5_6;
        pub const leftNeg5_6 = GeneratedStyledMethods.leftNeg5_6;
        pub const left1_12 = GeneratedStyledMethods.left1_12;
        pub const leftNeg1_12 = GeneratedStyledMethods.leftNeg1_12;
        pub const right = GeneratedStyledMethods.right;
        pub const right0 = GeneratedStyledMethods.right0;
        pub const rightNeg0 = GeneratedStyledMethods.rightNeg0;
        pub const right0p5 = GeneratedStyledMethods.right0p5;
        pub const rightNeg0p5 = GeneratedStyledMethods.rightNeg0p5;
        pub const right1 = GeneratedStyledMethods.right1;
        pub const rightNeg1 = GeneratedStyledMethods.rightNeg1;
        pub const right1p5 = GeneratedStyledMethods.right1p5;
        pub const rightNeg1p5 = GeneratedStyledMethods.rightNeg1p5;
        pub const right2 = GeneratedStyledMethods.right2;
        pub const rightNeg2 = GeneratedStyledMethods.rightNeg2;
        pub const right2p5 = GeneratedStyledMethods.right2p5;
        pub const rightNeg2p5 = GeneratedStyledMethods.rightNeg2p5;
        pub const right3 = GeneratedStyledMethods.right3;
        pub const rightNeg3 = GeneratedStyledMethods.rightNeg3;
        pub const right3p5 = GeneratedStyledMethods.right3p5;
        pub const rightNeg3p5 = GeneratedStyledMethods.rightNeg3p5;
        pub const right4 = GeneratedStyledMethods.right4;
        pub const rightNeg4 = GeneratedStyledMethods.rightNeg4;
        pub const right5 = GeneratedStyledMethods.right5;
        pub const rightNeg5 = GeneratedStyledMethods.rightNeg5;
        pub const right6 = GeneratedStyledMethods.right6;
        pub const rightNeg6 = GeneratedStyledMethods.rightNeg6;
        pub const right7 = GeneratedStyledMethods.right7;
        pub const rightNeg7 = GeneratedStyledMethods.rightNeg7;
        pub const right8 = GeneratedStyledMethods.right8;
        pub const rightNeg8 = GeneratedStyledMethods.rightNeg8;
        pub const right9 = GeneratedStyledMethods.right9;
        pub const rightNeg9 = GeneratedStyledMethods.rightNeg9;
        pub const right10 = GeneratedStyledMethods.right10;
        pub const rightNeg10 = GeneratedStyledMethods.rightNeg10;
        pub const right11 = GeneratedStyledMethods.right11;
        pub const rightNeg11 = GeneratedStyledMethods.rightNeg11;
        pub const right12 = GeneratedStyledMethods.right12;
        pub const rightNeg12 = GeneratedStyledMethods.rightNeg12;
        pub const right16 = GeneratedStyledMethods.right16;
        pub const rightNeg16 = GeneratedStyledMethods.rightNeg16;
        pub const right20 = GeneratedStyledMethods.right20;
        pub const rightNeg20 = GeneratedStyledMethods.rightNeg20;
        pub const right24 = GeneratedStyledMethods.right24;
        pub const rightNeg24 = GeneratedStyledMethods.rightNeg24;
        pub const right32 = GeneratedStyledMethods.right32;
        pub const rightNeg32 = GeneratedStyledMethods.rightNeg32;
        pub const right40 = GeneratedStyledMethods.right40;
        pub const rightNeg40 = GeneratedStyledMethods.rightNeg40;
        pub const right48 = GeneratedStyledMethods.right48;
        pub const rightNeg48 = GeneratedStyledMethods.rightNeg48;
        pub const right56 = GeneratedStyledMethods.right56;
        pub const rightNeg56 = GeneratedStyledMethods.rightNeg56;
        pub const right64 = GeneratedStyledMethods.right64;
        pub const rightNeg64 = GeneratedStyledMethods.rightNeg64;
        pub const right72 = GeneratedStyledMethods.right72;
        pub const rightNeg72 = GeneratedStyledMethods.rightNeg72;
        pub const right80 = GeneratedStyledMethods.right80;
        pub const rightNeg80 = GeneratedStyledMethods.rightNeg80;
        pub const right96 = GeneratedStyledMethods.right96;
        pub const rightNeg96 = GeneratedStyledMethods.rightNeg96;
        pub const right112 = GeneratedStyledMethods.right112;
        pub const rightNeg112 = GeneratedStyledMethods.rightNeg112;
        pub const right128 = GeneratedStyledMethods.right128;
        pub const rightNeg128 = GeneratedStyledMethods.rightNeg128;
        pub const rightAuto = GeneratedStyledMethods.rightAuto;
        pub const rightPx = GeneratedStyledMethods.rightPx;
        pub const rightNegPx = GeneratedStyledMethods.rightNegPx;
        pub const rightFull = GeneratedStyledMethods.rightFull;
        pub const rightNegFull = GeneratedStyledMethods.rightNegFull;
        pub const right1_2 = GeneratedStyledMethods.right1_2;
        pub const rightNeg1_2 = GeneratedStyledMethods.rightNeg1_2;
        pub const right1_3 = GeneratedStyledMethods.right1_3;
        pub const rightNeg1_3 = GeneratedStyledMethods.rightNeg1_3;
        pub const right2_3 = GeneratedStyledMethods.right2_3;
        pub const rightNeg2_3 = GeneratedStyledMethods.rightNeg2_3;
        pub const right1_4 = GeneratedStyledMethods.right1_4;
        pub const rightNeg1_4 = GeneratedStyledMethods.rightNeg1_4;
        pub const right2_4 = GeneratedStyledMethods.right2_4;
        pub const rightNeg2_4 = GeneratedStyledMethods.rightNeg2_4;
        pub const right3_4 = GeneratedStyledMethods.right3_4;
        pub const rightNeg3_4 = GeneratedStyledMethods.rightNeg3_4;
        pub const right1_5 = GeneratedStyledMethods.right1_5;
        pub const rightNeg1_5 = GeneratedStyledMethods.rightNeg1_5;
        pub const right2_5 = GeneratedStyledMethods.right2_5;
        pub const rightNeg2_5 = GeneratedStyledMethods.rightNeg2_5;
        pub const right3_5 = GeneratedStyledMethods.right3_5;
        pub const rightNeg3_5 = GeneratedStyledMethods.rightNeg3_5;
        pub const right4_5 = GeneratedStyledMethods.right4_5;
        pub const rightNeg4_5 = GeneratedStyledMethods.rightNeg4_5;
        pub const right1_6 = GeneratedStyledMethods.right1_6;
        pub const rightNeg1_6 = GeneratedStyledMethods.rightNeg1_6;
        pub const right5_6 = GeneratedStyledMethods.right5_6;
        pub const rightNeg5_6 = GeneratedStyledMethods.rightNeg5_6;
        pub const right1_12 = GeneratedStyledMethods.right1_12;
        pub const rightNeg1_12 = GeneratedStyledMethods.rightNeg1_12;
        pub const rounded = GeneratedStyledMethods.rounded;
        pub const roundedNone = GeneratedStyledMethods.roundedNone;
        pub const roundedXs = GeneratedStyledMethods.roundedXs;
        pub const roundedSm = GeneratedStyledMethods.roundedSm;
        pub const roundedMd = GeneratedStyledMethods.roundedMd;
        pub const roundedLg = GeneratedStyledMethods.roundedLg;
        pub const roundedXl = GeneratedStyledMethods.roundedXl;
        pub const rounded2xl = GeneratedStyledMethods.rounded2xl;
        pub const rounded3xl = GeneratedStyledMethods.rounded3xl;
        pub const roundedFull = GeneratedStyledMethods.roundedFull;
        pub const roundedT = GeneratedStyledMethods.roundedT;
        pub const roundedTNone = GeneratedStyledMethods.roundedTNone;
        pub const roundedTXs = GeneratedStyledMethods.roundedTXs;
        pub const roundedTSm = GeneratedStyledMethods.roundedTSm;
        pub const roundedTMd = GeneratedStyledMethods.roundedTMd;
        pub const roundedTLg = GeneratedStyledMethods.roundedTLg;
        pub const roundedTXl = GeneratedStyledMethods.roundedTXl;
        pub const roundedT2xl = GeneratedStyledMethods.roundedT2xl;
        pub const roundedT3xl = GeneratedStyledMethods.roundedT3xl;
        pub const roundedTFull = GeneratedStyledMethods.roundedTFull;
        pub const roundedB = GeneratedStyledMethods.roundedB;
        pub const roundedBNone = GeneratedStyledMethods.roundedBNone;
        pub const roundedBXs = GeneratedStyledMethods.roundedBXs;
        pub const roundedBSm = GeneratedStyledMethods.roundedBSm;
        pub const roundedBMd = GeneratedStyledMethods.roundedBMd;
        pub const roundedBLg = GeneratedStyledMethods.roundedBLg;
        pub const roundedBXl = GeneratedStyledMethods.roundedBXl;
        pub const roundedB2xl = GeneratedStyledMethods.roundedB2xl;
        pub const roundedB3xl = GeneratedStyledMethods.roundedB3xl;
        pub const roundedBFull = GeneratedStyledMethods.roundedBFull;
        pub const roundedR = GeneratedStyledMethods.roundedR;
        pub const roundedRNone = GeneratedStyledMethods.roundedRNone;
        pub const roundedRXs = GeneratedStyledMethods.roundedRXs;
        pub const roundedRSm = GeneratedStyledMethods.roundedRSm;
        pub const roundedRMd = GeneratedStyledMethods.roundedRMd;
        pub const roundedRLg = GeneratedStyledMethods.roundedRLg;
        pub const roundedRXl = GeneratedStyledMethods.roundedRXl;
        pub const roundedR2xl = GeneratedStyledMethods.roundedR2xl;
        pub const roundedR3xl = GeneratedStyledMethods.roundedR3xl;
        pub const roundedRFull = GeneratedStyledMethods.roundedRFull;
        pub const roundedL = GeneratedStyledMethods.roundedL;
        pub const roundedLNone = GeneratedStyledMethods.roundedLNone;
        pub const roundedLXs = GeneratedStyledMethods.roundedLXs;
        pub const roundedLSm = GeneratedStyledMethods.roundedLSm;
        pub const roundedLMd = GeneratedStyledMethods.roundedLMd;
        pub const roundedLLg = GeneratedStyledMethods.roundedLLg;
        pub const roundedLXl = GeneratedStyledMethods.roundedLXl;
        pub const roundedL2xl = GeneratedStyledMethods.roundedL2xl;
        pub const roundedL3xl = GeneratedStyledMethods.roundedL3xl;
        pub const roundedLFull = GeneratedStyledMethods.roundedLFull;
        pub const roundedTl = GeneratedStyledMethods.roundedTl;
        pub const roundedTlNone = GeneratedStyledMethods.roundedTlNone;
        pub const roundedTlXs = GeneratedStyledMethods.roundedTlXs;
        pub const roundedTlSm = GeneratedStyledMethods.roundedTlSm;
        pub const roundedTlMd = GeneratedStyledMethods.roundedTlMd;
        pub const roundedTlLg = GeneratedStyledMethods.roundedTlLg;
        pub const roundedTlXl = GeneratedStyledMethods.roundedTlXl;
        pub const roundedTl2xl = GeneratedStyledMethods.roundedTl2xl;
        pub const roundedTl3xl = GeneratedStyledMethods.roundedTl3xl;
        pub const roundedTlFull = GeneratedStyledMethods.roundedTlFull;
        pub const roundedTr = GeneratedStyledMethods.roundedTr;
        pub const roundedTrNone = GeneratedStyledMethods.roundedTrNone;
        pub const roundedTrXs = GeneratedStyledMethods.roundedTrXs;
        pub const roundedTrSm = GeneratedStyledMethods.roundedTrSm;
        pub const roundedTrMd = GeneratedStyledMethods.roundedTrMd;
        pub const roundedTrLg = GeneratedStyledMethods.roundedTrLg;
        pub const roundedTrXl = GeneratedStyledMethods.roundedTrXl;
        pub const roundedTr2xl = GeneratedStyledMethods.roundedTr2xl;
        pub const roundedTr3xl = GeneratedStyledMethods.roundedTr3xl;
        pub const roundedTrFull = GeneratedStyledMethods.roundedTrFull;
        pub const roundedBl = GeneratedStyledMethods.roundedBl;
        pub const roundedBlNone = GeneratedStyledMethods.roundedBlNone;
        pub const roundedBlXs = GeneratedStyledMethods.roundedBlXs;
        pub const roundedBlSm = GeneratedStyledMethods.roundedBlSm;
        pub const roundedBlMd = GeneratedStyledMethods.roundedBlMd;
        pub const roundedBlLg = GeneratedStyledMethods.roundedBlLg;
        pub const roundedBlXl = GeneratedStyledMethods.roundedBlXl;
        pub const roundedBl2xl = GeneratedStyledMethods.roundedBl2xl;
        pub const roundedBl3xl = GeneratedStyledMethods.roundedBl3xl;
        pub const roundedBlFull = GeneratedStyledMethods.roundedBlFull;
        pub const roundedBr = GeneratedStyledMethods.roundedBr;
        pub const roundedBrNone = GeneratedStyledMethods.roundedBrNone;
        pub const roundedBrXs = GeneratedStyledMethods.roundedBrXs;
        pub const roundedBrSm = GeneratedStyledMethods.roundedBrSm;
        pub const roundedBrMd = GeneratedStyledMethods.roundedBrMd;
        pub const roundedBrLg = GeneratedStyledMethods.roundedBrLg;
        pub const roundedBrXl = GeneratedStyledMethods.roundedBrXl;
        pub const roundedBr2xl = GeneratedStyledMethods.roundedBr2xl;
        pub const roundedBr3xl = GeneratedStyledMethods.roundedBr3xl;
        pub const roundedBrFull = GeneratedStyledMethods.roundedBrFull;
        pub const border = GeneratedStyledMethods.border;
        pub const border0 = GeneratedStyledMethods.border0;
        pub const border1 = GeneratedStyledMethods.border1;
        pub const border2 = GeneratedStyledMethods.border2;
        pub const border3 = GeneratedStyledMethods.border3;
        pub const border4 = GeneratedStyledMethods.border4;
        pub const border5 = GeneratedStyledMethods.border5;
        pub const border6 = GeneratedStyledMethods.border6;
        pub const border7 = GeneratedStyledMethods.border7;
        pub const border8 = GeneratedStyledMethods.border8;
        pub const border9 = GeneratedStyledMethods.border9;
        pub const border10 = GeneratedStyledMethods.border10;
        pub const border11 = GeneratedStyledMethods.border11;
        pub const border12 = GeneratedStyledMethods.border12;
        pub const border16 = GeneratedStyledMethods.border16;
        pub const border20 = GeneratedStyledMethods.border20;
        pub const border24 = GeneratedStyledMethods.border24;
        pub const border32 = GeneratedStyledMethods.border32;
        pub const borderT = GeneratedStyledMethods.borderT;
        pub const borderT0 = GeneratedStyledMethods.borderT0;
        pub const borderT1 = GeneratedStyledMethods.borderT1;
        pub const borderT2 = GeneratedStyledMethods.borderT2;
        pub const borderT3 = GeneratedStyledMethods.borderT3;
        pub const borderT4 = GeneratedStyledMethods.borderT4;
        pub const borderT5 = GeneratedStyledMethods.borderT5;
        pub const borderT6 = GeneratedStyledMethods.borderT6;
        pub const borderT7 = GeneratedStyledMethods.borderT7;
        pub const borderT8 = GeneratedStyledMethods.borderT8;
        pub const borderT9 = GeneratedStyledMethods.borderT9;
        pub const borderT10 = GeneratedStyledMethods.borderT10;
        pub const borderT11 = GeneratedStyledMethods.borderT11;
        pub const borderT12 = GeneratedStyledMethods.borderT12;
        pub const borderT16 = GeneratedStyledMethods.borderT16;
        pub const borderT20 = GeneratedStyledMethods.borderT20;
        pub const borderT24 = GeneratedStyledMethods.borderT24;
        pub const borderT32 = GeneratedStyledMethods.borderT32;
        pub const borderB = GeneratedStyledMethods.borderB;
        pub const borderB0 = GeneratedStyledMethods.borderB0;
        pub const borderB1 = GeneratedStyledMethods.borderB1;
        pub const borderB2 = GeneratedStyledMethods.borderB2;
        pub const borderB3 = GeneratedStyledMethods.borderB3;
        pub const borderB4 = GeneratedStyledMethods.borderB4;
        pub const borderB5 = GeneratedStyledMethods.borderB5;
        pub const borderB6 = GeneratedStyledMethods.borderB6;
        pub const borderB7 = GeneratedStyledMethods.borderB7;
        pub const borderB8 = GeneratedStyledMethods.borderB8;
        pub const borderB9 = GeneratedStyledMethods.borderB9;
        pub const borderB10 = GeneratedStyledMethods.borderB10;
        pub const borderB11 = GeneratedStyledMethods.borderB11;
        pub const borderB12 = GeneratedStyledMethods.borderB12;
        pub const borderB16 = GeneratedStyledMethods.borderB16;
        pub const borderB20 = GeneratedStyledMethods.borderB20;
        pub const borderB24 = GeneratedStyledMethods.borderB24;
        pub const borderB32 = GeneratedStyledMethods.borderB32;
        pub const borderR = GeneratedStyledMethods.borderR;
        pub const borderR0 = GeneratedStyledMethods.borderR0;
        pub const borderR1 = GeneratedStyledMethods.borderR1;
        pub const borderR2 = GeneratedStyledMethods.borderR2;
        pub const borderR3 = GeneratedStyledMethods.borderR3;
        pub const borderR4 = GeneratedStyledMethods.borderR4;
        pub const borderR5 = GeneratedStyledMethods.borderR5;
        pub const borderR6 = GeneratedStyledMethods.borderR6;
        pub const borderR7 = GeneratedStyledMethods.borderR7;
        pub const borderR8 = GeneratedStyledMethods.borderR8;
        pub const borderR9 = GeneratedStyledMethods.borderR9;
        pub const borderR10 = GeneratedStyledMethods.borderR10;
        pub const borderR11 = GeneratedStyledMethods.borderR11;
        pub const borderR12 = GeneratedStyledMethods.borderR12;
        pub const borderR16 = GeneratedStyledMethods.borderR16;
        pub const borderR20 = GeneratedStyledMethods.borderR20;
        pub const borderR24 = GeneratedStyledMethods.borderR24;
        pub const borderR32 = GeneratedStyledMethods.borderR32;
        pub const borderL = GeneratedStyledMethods.borderL;
        pub const borderL0 = GeneratedStyledMethods.borderL0;
        pub const borderL1 = GeneratedStyledMethods.borderL1;
        pub const borderL2 = GeneratedStyledMethods.borderL2;
        pub const borderL3 = GeneratedStyledMethods.borderL3;
        pub const borderL4 = GeneratedStyledMethods.borderL4;
        pub const borderL5 = GeneratedStyledMethods.borderL5;
        pub const borderL6 = GeneratedStyledMethods.borderL6;
        pub const borderL7 = GeneratedStyledMethods.borderL7;
        pub const borderL8 = GeneratedStyledMethods.borderL8;
        pub const borderL9 = GeneratedStyledMethods.borderL9;
        pub const borderL10 = GeneratedStyledMethods.borderL10;
        pub const borderL11 = GeneratedStyledMethods.borderL11;
        pub const borderL12 = GeneratedStyledMethods.borderL12;
        pub const borderL16 = GeneratedStyledMethods.borderL16;
        pub const borderL20 = GeneratedStyledMethods.borderL20;
        pub const borderL24 = GeneratedStyledMethods.borderL24;
        pub const borderL32 = GeneratedStyledMethods.borderL32;
        pub const borderX = GeneratedStyledMethods.borderX;
        pub const borderX0 = GeneratedStyledMethods.borderX0;
        pub const borderX1 = GeneratedStyledMethods.borderX1;
        pub const borderX2 = GeneratedStyledMethods.borderX2;
        pub const borderX3 = GeneratedStyledMethods.borderX3;
        pub const borderX4 = GeneratedStyledMethods.borderX4;
        pub const borderX5 = GeneratedStyledMethods.borderX5;
        pub const borderX6 = GeneratedStyledMethods.borderX6;
        pub const borderX7 = GeneratedStyledMethods.borderX7;
        pub const borderX8 = GeneratedStyledMethods.borderX8;
        pub const borderX9 = GeneratedStyledMethods.borderX9;
        pub const borderX10 = GeneratedStyledMethods.borderX10;
        pub const borderX11 = GeneratedStyledMethods.borderX11;
        pub const borderX12 = GeneratedStyledMethods.borderX12;
        pub const borderX16 = GeneratedStyledMethods.borderX16;
        pub const borderX20 = GeneratedStyledMethods.borderX20;
        pub const borderX24 = GeneratedStyledMethods.borderX24;
        pub const borderX32 = GeneratedStyledMethods.borderX32;
        pub const borderY = GeneratedStyledMethods.borderY;
        pub const borderY0 = GeneratedStyledMethods.borderY0;
        pub const borderY1 = GeneratedStyledMethods.borderY1;
        pub const borderY2 = GeneratedStyledMethods.borderY2;
        pub const borderY3 = GeneratedStyledMethods.borderY3;
        pub const borderY4 = GeneratedStyledMethods.borderY4;
        pub const borderY5 = GeneratedStyledMethods.borderY5;
        pub const borderY6 = GeneratedStyledMethods.borderY6;
        pub const borderY7 = GeneratedStyledMethods.borderY7;
        pub const borderY8 = GeneratedStyledMethods.borderY8;
        pub const borderY9 = GeneratedStyledMethods.borderY9;
        pub const borderY10 = GeneratedStyledMethods.borderY10;
        pub const borderY11 = GeneratedStyledMethods.borderY11;
        pub const borderY12 = GeneratedStyledMethods.borderY12;
        pub const borderY16 = GeneratedStyledMethods.borderY16;
        pub const borderY20 = GeneratedStyledMethods.borderY20;
        pub const borderY24 = GeneratedStyledMethods.borderY24;
        pub const borderY32 = GeneratedStyledMethods.borderY32;
        pub const visible = GeneratedStyledMethods.visible;
        pub const invisible = GeneratedStyledMethods.invisible;
        pub const relative = GeneratedStyledMethods.relative;
        pub const absolute = GeneratedStyledMethods.absolute;
        pub const overflowHidden = GeneratedStyledMethods.overflowHidden;
        pub const overflowXHidden = GeneratedStyledMethods.overflowXHidden;
        pub const overflowYHidden = GeneratedStyledMethods.overflowYHidden;
        pub const cursorDefault = GeneratedStyledMethods.cursorDefault;
        pub const cursorPointer = GeneratedStyledMethods.cursorPointer;
        pub const cursorText = GeneratedStyledMethods.cursorText;
        pub const cursorMove = GeneratedStyledMethods.cursorMove;
        pub const cursorNotAllowed = GeneratedStyledMethods.cursorNotAllowed;
        pub const cursorContextMenu = GeneratedStyledMethods.cursorContextMenu;
        pub const cursorCrosshair = GeneratedStyledMethods.cursorCrosshair;
        pub const cursorAlias = GeneratedStyledMethods.cursorAlias;
        pub const cursorCopy = GeneratedStyledMethods.cursorCopy;
        pub const cursorNoDrop = GeneratedStyledMethods.cursorNoDrop;
        pub const cursorGrab = GeneratedStyledMethods.cursorGrab;
        pub const cursorGrabbing = GeneratedStyledMethods.cursorGrabbing;
        pub const cursorEwResize = GeneratedStyledMethods.cursorEwResize;
        pub const cursorNsResize = GeneratedStyledMethods.cursorNsResize;
        pub const cursorColResize = GeneratedStyledMethods.cursorColResize;
        pub const cursorRowResize = GeneratedStyledMethods.cursorRowResize;
        pub const cursorNResize = GeneratedStyledMethods.cursorNResize;
        pub const cursorEResize = GeneratedStyledMethods.cursorEResize;
        pub const cursorSResize = GeneratedStyledMethods.cursorSResize;
        pub const cursorWResize = GeneratedStyledMethods.cursorWResize;
        pub const shadow2xs = GeneratedStyledMethods.shadow2xs;
        pub const shadowXs = GeneratedStyledMethods.shadowXs;
        pub const shadowSm = GeneratedStyledMethods.shadowSm;
        pub const shadowMd = GeneratedStyledMethods.shadowMd;
        pub const shadowLg = GeneratedStyledMethods.shadowLg;
        pub const shadowXl = GeneratedStyledMethods.shadowXl;
        pub const shadow2xl = GeneratedStyledMethods.shadow2xl;
        // zpui:styled-forwarders end
    };
}

// ---------------------------------------------------------------------------------------
// Interactivity
// ---------------------------------------------------------------------------------------

pub const MouseMode = union(enum) {
    /// Bubble phase, matching button, over this element.
    bubble_button: input.MouseButton,
    /// Bubble phase, any button, over this element.
    bubble_any,
    /// Capture phase, over this element.
    capture_any,
    /// Capture phase, outside this element (any button).
    out_any,
    /// Capture phase, matching button, outside this element.
    out_button: input.MouseButton,
    /// Bubble phase when this element should handle scroll.
    scroll,
};

pub fn MouseEntry(comptime Ev: type) type {
    return struct { listener: Listener(Ev), mode: MouseMode };
}

pub fn KeyEntry(comptime Ev: type) type {
    return struct { listener: Listener(Ev), phase: DispatchPhase };
}

/// A `Listener(T)` with `T` erased (all listeners share one layout).
const ErasedListener = struct {
    func: *const anyopaque,
    data: ListenerData,

    fn erase(l: anytype) ErasedListener {
        return .{ .func = @ptrCast(l.func), .data = l.data };
    }
    fn get(self: ErasedListener, comptime T: type) Listener(T) {
        return .{ .func = @ptrCast(@alignCast(self.func)), .data = self.data };
    }
};

const ActionEntry = struct {
    register: *const fn (window: *Window, l: ErasedListener, phase: DispatchPhase) void,
    listener: ErasedListener,
    phase: DispatchPhase,

    fn init(comptime A: type, l: Listener(A), which: DispatchPhase) ActionEntry {
        const Gen = struct {
            const Ctx = struct { l: Listener(A), phase: DispatchPhase };
            fn register(window: *Window, el: ErasedListener, p: DispatchPhase) void {
                window.onAction(A, Ctx{ .l = el.get(A), .phase = p }, call);
            }
            fn call(c: *const Ctx, action: *const A, phase: DispatchPhase, window: *Window, app: *App) void {
                if (phase == c.phase) c.l.callIn(action, window, app);
            }
        };
        return .{ .register = Gen.register, .listener = .erase(l), .phase = which };
    }
};

const DropEntry = struct {
    type_id: TypeId,
    call: *const fn (l: ErasedListener, value: *const anyopaque, window: *Window, app: *App) void,
    listener: ErasedListener,

    fn init(comptime T: type, l: Listener(T)) DropEntry {
        const Gen = struct {
            fn call(el: ErasedListener, value: *const anyopaque, window: *Window, app: *App) void {
                el.get(T).callIn(@ptrCast(@alignCast(value)), window, app);
            }
        };
        return .{ .type_id = type_id.typeId(T), .call = Gen.call, .listener = .erase(l) };
    }
};

const DragMoveEntry = struct {
    register: *const fn (window: *Window, l: ErasedListener, hitbox: Hitbox) void,
    listener: ErasedListener,

    fn init(comptime T: type, l: Listener(events.DragMoveEvent(T))) DragMoveEntry {
        const Gen = struct {
            const Ctx = struct { l: Listener(events.DragMoveEvent(T)), bounds: Bounds };
            fn register(window: *Window, el: ErasedListener, hitbox: Hitbox) void {
                window.onMouseEvent(input.MouseMoveEvent, Ctx{ .l = el.get(events.DragMoveEvent(T)), .bounds = hitbox.bounds }, call);
            }
            fn call(c: *Ctx, ev: *const input.MouseMoveEvent, phase: DispatchPhase, window: *Window, app: *App) void {
                if (phase != .capture) return;
                const value = app.activeDrag(T) orelse return;
                const dm: events.DragMoveEvent(T) = .{ .event = ev.*, .bounds = c.bounds, .value = value };
                c.l.callIn(&dm, window, app);
            }
        };
        return .{ .register = Gen.register, .listener = .erase(l) };
    }
};

/// What `onDrag` captured: the value (copied into element state at paint) and the preview builder.
const DragSpec = struct {
    type_id: TypeId,
    bytes: []const u8,
    alignment: u8,
    build: *const fn (value: *const anyopaque, offset: Point, window: *Window, app: *App) AnyView,

    fn init(value: anytype, comptime build: anytype) DragSpec {
        const T = @TypeOf(value);
        const p = arena_mod.current().create(T, value);
        const Gen = struct {
            fn call(v: *const anyopaque, offset: Point, window: *Window, app: *App) AnyView {
                const entity = build(@as(*const T, @ptrCast(@alignCast(v))), offset, window, app);
                return AnyView.fromEntity(entity);
            }
        };
        return .{ .type_id = type_id.typeId(T), .bytes = std.mem.asBytes(p), .alignment = @alignOf(T), .build = Gen.call };
    }
};

/// Builds tooltip views (gpui `TooltipBuilder`).
pub const TooltipBuilder = struct {
    func: *const fn (data: *const ListenerData, window: *Window, app: *App) AnyView,
    data: ListenerData = .{},
    hoverable: bool = false,

    fn init(comptime build: anytype, data: anytype) TooltipBuilder {
        const D = @TypeOf(data);
        const Gen = struct {
            fn call(ld: *const ListenerData, window: *Window, app: *App) AnyView {
                const e = if (D == void) build(window, app) else build(ld.get(D), window, app);
                return AnyView.fromEntity(e);
            }
        };
        var ld: ListenerData = .{};
        if (D != void) ld.set(data);
        return .{ .func = Gen.call, .data = ld };
    }
};

pub const GroupStyle = struct { group: []const u8, style: *StyleRefinement };
const DragOverStyle = struct { type_id: TypeId, style: *StyleRefinement };
const GroupDragOverStyle = struct { type_id: TypeId, group: []const u8, style: *StyleRefinement };

/// gpui `Interactivity`: styles and listeners of an interactive element.
pub const Interactivity = struct {
    element_id: ?ElementId = null,
    key_context: ?union(enum) { source: []const u8, parsed: KeyContext } = null,
    focusable: bool = false,
    tracked_focus_handle: ?FocusHandle = null,
    tracked_scroll_handle: ?ScrollHandle = null,
    group: ?[]const u8 = null,
    base_style: StyleRefinement = .{},
    /// `computeStyle`'s result for an element without state-dependent styles (this frame).
    static_style: ?*const Style = null,
    focus_style: ?*StyleRefinement = null,
    in_focus_style: ?*StyleRefinement = null,
    focus_visible_style: ?*StyleRefinement = null,
    hover_style: ?*StyleRefinement = null,
    group_hover_style: ?GroupStyle = null,
    active_style: ?*StyleRefinement = null,
    group_active_style: ?GroupStyle = null,
    drag_over_styles: std.ArrayList(DragOverStyle) = .empty,
    group_drag_over_styles: std.ArrayList(GroupDragOverStyle) = .empty,
    mouse_down_listeners: std.ArrayList(MouseEntry(input.MouseDownEvent)) = .empty,
    mouse_up_listeners: std.ArrayList(MouseEntry(input.MouseUpEvent)) = .empty,
    mouse_move_listeners: std.ArrayList(MouseEntry(input.MouseMoveEvent)) = .empty,
    mouse_exit_listeners: std.ArrayList(MouseEntry(input.MouseExitEvent)) = .empty,
    scroll_wheel_listeners: std.ArrayList(MouseEntry(input.ScrollWheelEvent)) = .empty,
    key_down_listeners: std.ArrayList(KeyEntry(input.KeyDownEvent)) = .empty,
    key_up_listeners: std.ArrayList(KeyEntry(input.KeyUpEvent)) = .empty,
    modifiers_changed_listeners: std.ArrayList(Listener(input.ModifiersChangedEvent)) = .empty,
    action_listeners: std.ArrayList(ActionEntry) = .empty,
    drop_listeners: std.ArrayList(DropEntry) = .empty,
    drag_move_listeners: std.ArrayList(DragMoveEntry) = .empty,
    can_drop: ?*const fn (*const anyopaque, TypeId, *Window, *App) bool = null,
    click_listeners: std.ArrayList(Listener(ClickEvent)) = .empty,
    aux_click_listeners: std.ArrayList(Listener(ClickEvent)) = .empty,
    drag: ?DragSpec = null,
    hover_listener: ?Listener(bool) = null,
    tooltip: ?TooltipBuilder = null,
    tooltip_show_delay_ns: ?u64 = null,
    hitbox_behavior: window_mod.HitboxBehavior = .normal,
    tab_index: ?isize = null,
    tab_group: bool = false,
    tab_stop: bool = false,
    /// Accessibility: role (an element with an id and a role is a tree node), declared
    /// properties (arena) and `onA11yAction` handlers.
    a11y_role: ?a11y.Role = null,
    aria: ?*a11y.Info = null,
    a11y_action_listeners: std.ArrayList(A11yActionEntry) = .empty,
    /// The computed style hid the element (`display: none`): no accessibility node.
    a11y_hidden: bool = false,

    // Computed during the frame.
    /// Scroll offset storage (element state or tracked handle), set in request layout.
    scroll_offset: ?*Point = null,
    content_size: Size = .zero,
    /// Hover state after paint (if a hitbox was inserted).
    hovered: ?bool = null,
    /// Pressed state after prepaint.
    active: ?bool = null,
    tooltip_id: ?u64 = null,

    /// The accessibility node of an element with this interactivity (zui `a11y_role` +
    /// `write_a11y_info`): declared role and aria properties, `click` when it has click
    /// listeners, `focus` (via its focus handle) when focusable, custom actions.
    pub fn a11yNode(self: *const Interactivity, gid: GlobalElementId, bounds: Bounds, window: *Window) ?a11y.NodeSpec {
        if (self.a11y_hidden) return null;
        const r = self.a11y_role orelse {
            // Audit: interactive elements are expected to declare a role.
            const clickable = self.click_listeners.items.len > 0;
            const focusable = if (self.tracked_focus_handle) |h| h.tab_stop else false;
            if (clickable or focusable) {
                var buf: [96]u8 = undefined;
                const name: []const u8 = if (self.element_id) |e| switch (e) {
                    .name => |n| n,
                    .named_integer => |ni| std.fmt.bufPrint(&buf, "{s}#{d}", .{ ni.name, ni.index }) catch ni.name,
                    .integer => |i| std.fmt.bufPrint(&buf, "#{d}", .{i}) catch "#",
                    else => @tagName(e),
                } else "";
                window.a11yNoteUnroled(gid.toKey(), bounds, name, clickable, focusable);
            }
            return null;
        };
        var info: a11y.Info = if (self.aria) |a| a.* else .{};
        if (self.click_listeners.items.len > 0) info.actions.insert(.click);
        const node_id = a11y.NodeId.fromGlobal(gid.toKey());
        for (self.a11y_action_listeners.items) |e| {
            info.actions.insert(e.action);
            window.onA11yAction(node_id, e.action, e.listener);
        }
        return .{
            .id = node_id,
            .role = r,
            .bounds = bounds,
            .info = info,
            .focus_id = if (self.tracked_focus_handle) |h| @intFromEnum(h.id) else null,
        };
    }

    fn wantsScroll(self: *const Interactivity) bool {
        return self.base_style.overflow.x == .scroll or self.base_style.overflow.y == .scroll;
    }

    /// gpui `Interactivity::request_layout` minus the closure: prepares element state and
    /// returns the computed style.
    pub fn requestLayoutStyle(self: *Interactivity, gid: ?GlobalElementId, window: *Window, cx: *App) Style {
        const st = window.optionalElementState(InteractiveElementState, gid);
        if (st) |s| if (cx.hasActiveDrag()) {
            s.pending_mouse_down = null;
            s.clicked_state = .{};
        };
        if (self.focusable and self.tracked_focus_handle == null) if (st) |s| {
            if (s.focus_handle == null) s.focus_handle = cx.focusHandle();
            var h = s.focus_handle.?;
            h.tab_stop = self.tab_stop;
            if (self.tab_index) |i| h.tab_index = i;
            self.tracked_focus_handle = h;
        };
        if (self.tracked_focus_handle) |*h| if (self.tab_index) |i| {
            h.tab_index = i;
            h.tab_stop = self.tab_stop;
        };
        if (self.tracked_scroll_handle) |h| {
            if (st) |s| s.setScrollHandle(h);
            self.scroll_offset = &h.state.offset;
        } else if (self.wantsScroll()) if (st) |s| {
            self.scroll_offset = &s.scroll_offset;
        };
        self.static_style = null; // layout starts from the current refinements
        const computed = self.computeStyle(null, st, window, cx);
        self.a11y_hidden = computed.display == .none;
        return computed;
    }

    /// gpui `compute_style_internal`.
    pub fn computeStyle(self: *Interactivity, hitbox: ?Hitbox, st: ?*InteractiveElementState, window: *Window, cx: *App) Style {
        if (arena_mod.currentOrNull() == null) return self.computeStyleValue(hitbox, st, window, cx);
        return self.styleRef(hitbox, st, window, cx).*;
    }

    /// `computeStyle` in the frame arena (no copy of the large `Style` per phase): an
    /// element without state-dependent styles gets the same pointer in every phase.
    pub fn styleRef(self: *Interactivity, hitbox: ?Hitbox, st: ?*InteractiveElementState, window: *Window, cx: *App) *const Style {
        if (self.isStaticStyle(cx)) {
            if (self.static_style) |memo| return memo;
        }
        const a = arena_mod.current();
        const out = a.create(Style, self.computeStyleValue(hitbox, st, window, cx));
        if (self.isStaticStyle(cx)) self.static_style = out;
        return out;
    }

    /// No focus, hover, active or drag-over styles (and no drag in flight): the style
    /// is the same in every phase of the frame.
    fn isStaticStyle(self: *const Interactivity, cx: *const App) bool {
        return self.focus_style == null and self.in_focus_style == null and self.focus_visible_style == null and
            self.hover_style == null and self.group_hover_style == null and self.active_style == null and
            self.group_active_style == null and cx.active_drag == null;
    }

    fn computeStyleValue(self: *Interactivity, hitbox: ?Hitbox, st: ?*InteractiveElementState, window: *Window, cx: *App) Style {
        var s: Style = .{};
        refine.refine(&s, self.base_style);
        if (self.isStaticStyle(cx)) return s;
        if (self.tracked_focus_handle) |fh| {
            if (self.in_focus_style) |r| if (fh.withinFocused(window)) refine.refine(&s, r.*);
            if (self.focus_style) |r| if (fh.isFocused(window)) refine.refine(&s, r.*);
            if (self.focus_visible_style) |r| if (fh.isFocused(window) and window.last_input_was_keyboard) refine.refine(&s, r.*);
        }
        if (!cx.hasActiveDrag()) {
            if (self.group_hover_style) |gh| {
                const hovered = if (window.groupHitbox(gh.group)) |g| g.isHovered(window) else if (st) |e| e.hover_state.group else false;
                if (hovered) refine.refine(&s, gh.style.*);
            }
            if (self.hover_style) |r| {
                const hovered = if (hitbox) |h| h.isHovered(window) else if (st) |e| e.hover_state.element else false;
                if (hovered) refine.refine(&s, r.*);
            }
        }
        if (hitbox) |h| if (cx.active_drag) |drag| {
            var can = true;
            if (self.can_drop) |pred| can = pred(drag.value, drag.type_id, window, cx);
            if (can) {
                for (self.group_drag_over_styles.items) |g| {
                    if (g.type_id != drag.type_id) continue;
                    if (window.groupHitbox(g.group)) |gid| if (gid.isHovered(window)) refine.refine(&s, g.style.*);
                }
                for (self.drag_over_styles.items) |d| {
                    if (d.type_id == drag.type_id and h.isHovered(window)) refine.refine(&s, d.style.*);
                }
            }
            s.mouse_cursor = drag.cursor_style;
        };
        if (st) |e| {
            if (e.clicked_state.group) if (self.group_active_style) |g| refine.refine(&s, g.style.*);
            if (e.clicked_state.element) if (self.active_style) |r| refine.refine(&s, r.*);
        }
        return s;
    }

    fn shouldInsertHitbox(self: *const Interactivity, s: *const Style) bool {
        return self.hitbox_behavior != .normal or s.mouse_cursor != null or self.group != null or
            self.scroll_offset != null or self.tracked_focus_handle != null or self.hover_style != null or
            self.group_hover_style != null or self.hover_listener != null or
            self.mouse_up_listeners.items.len > 0 or self.mouse_down_listeners.items.len > 0 or
            self.mouse_move_listeners.items.len > 0 or self.mouse_exit_listeners.items.len > 0 or
            self.click_listeners.items.len > 0 or self.aux_click_listeners.items.len > 0 or
            self.scroll_wheel_listeners.items.len > 0 or self.drag != null or
            self.drop_listeners.items.len > 0 or self.drag_over_styles.items.len > 0 or self.tooltip != null or
            self.active_style != null;
    }

    /// Result of `prepaintBegin`; pass to `prepaintEnd` after prepainting children.
    pub const PrepaintScope = struct {
        style: *const Style,
        hitbox: ?Hitbox,
        scroll_offset: Point,
        text: ?style_mod.TextStyleRefinement,
        mask: ?window_mod.ContentMask,
    };

    /// gpui `Interactivity::prepaint` up to the children closure.
    pub fn prepaintBegin(self: *Interactivity, gid: ?GlobalElementId, bounds: Bounds, content_size: Size, window: *Window, cx: *App) PrepaintScope {
        self.content_size = content_size;
        if (self.tracked_focus_handle) |fh| window.setFocusHandle(fh);
        const st = window.optionalElementState(InteractiveElementState, gid);
        const s = self.styleRef(null, st, window, cx);
        if (st) |e| {
            self.active = e.clicked_state.element;
            if (e.active_tooltip) |*at| {
                if (self.tooltip != null) {
                    self.tooltip_id = tooltipOnWindow(e, at, window);
                } else e.clearTooltip(window, cx);
            }
        }
        const text: ?style_mod.TextStyleRefinement = if (s.textStyle()) |t| t.* else null;
        window.pushTextStyle(text);
        const mask: ?window_mod.ContentMask = if (s.overflowMask(bounds, window.remSize())) |m| .{ .bounds = m } else null;
        window.pushContentMask(mask);
        const hitbox: ?Hitbox = if (self.shouldInsertHitbox(s)) window.insertHitbox(bounds, self.hitbox_behavior) else null;
        const offset = self.clampScrollPosition(bounds, s, window);
        return .{ .style = s, .hitbox = hitbox, .scroll_offset = offset, .text = text, .mask = mask };
    }

    pub fn prepaintEnd(_: *Interactivity, scope: *const PrepaintScope, window: *Window) void {
        window.popContentMask(scope.mask);
        window.popTextStyle(scope.text);
    }

    fn clampScrollPosition(self: *Interactivity, bounds: Bounds, s: *const Style, window: *Window) Point {
        const offset = self.scroll_offset orelse return .zero;
        var scroll_to_bottom = false;
        if (self.tracked_scroll_handle) |h| {
            h.state.overflow = .{ .x = s.overflow.x, .y = s.overflow.y };
            scroll_to_bottom = h.state.scroll_to_bottom;
            h.state.scroll_to_bottom = false;
        }
        const rem = window.remSize();
        const base: style_mod.AbsoluteLength = .{ .pixels = bounds.size.width };
        const pad_x = s.padding.left.toPixels(base, rem) + s.padding.right.toPixels(base, rem);
        const pad_y = s.padding.top.toPixels(base, rem) + s.padding.bottom.toPixels(base, rem);
        const round2 = struct {
            fn f(v: f32) f32 {
                return @round(v * 100) / 100;
            }
        }.f;
        const max: Point = .{
            .x = @max(round2(self.content_size.width + pad_x - bounds.size.width), 0),
            .y = @max(round2(self.content_size.height + pad_y - bounds.size.height), 0),
        };
        offset.x = std.math.clamp(offset.x, -max.x, 0);
        offset.y = if (scroll_to_bottom) -max.y else std.math.clamp(offset.y, -max.y, 0);
        if (self.tracked_scroll_handle) |h| {
            h.state.max_offset = max;
            h.state.bounds = bounds;
        }
        return offset.*;
    }

    /// Result of `paintBegin`; pass to `paintEnd` after painting children.
    pub const PaintScope = struct {
        style: *const Style,
        /// Visibility hidden: nothing was pushed, skip children and `paintEnd` work.
        hidden: bool,
        opacity: f32 = 1,
        text: ?style_mod.TextStyleRefinement = null,
        mask: ?window_mod.ContentMask = null,
        tab_group: ?isize = null,
        group_pushed: bool = false,
        bounds: Bounds,
    };

    /// gpui `Interactivity::paint` up to the children closure.
    pub fn paintBegin(self: *Interactivity, gid: ?GlobalElementId, bounds: Bounds, hitbox: ?Hitbox, window: *Window, cx: *App) PaintScope {
        self.hovered = if (hitbox) |h| h.isHovered(window) else null;
        const st = window.optionalElementState(InteractiveElementState, gid);
        const s = self.styleRef(hitbox, st, window, cx);
        self.paintHoverGroupHandler(window);
        if (s.visibility == .hidden) return .{ .style = s, .hidden = true, .bounds = bounds };

        var scope: PaintScope = .{ .style = s, .hidden = false, .bounds = bounds };
        scope.opacity = window.pushOpacity(s.opacity);
        window.paintStyle(scope.style, bounds);
        scope.text = if (s.textStyle()) |t| t.* else null;
        window.pushTextStyle(scope.text);
        scope.mask = if (s.overflowMask(bounds, window.remSize())) |m| .{ .bounds = m } else null;
        window.pushContentMask(scope.mask);
        scope.tab_group = if (self.tab_group) self.tab_index else null;
        window.beginTabGroup(scope.tab_group);
        if (self.tracked_focus_handle) |fh| window.insertTabStop(fh);
        if (hitbox) |h| {
            if (cx.active_drag) |drag| {
                if (drag.cursor_style) |c| window.setWindowCursorStyle(c);
            } else if (s.mouse_cursor) |c| window.setCursorStyle(c, h);
            if (self.group) |g| {
                window.pushGroupHitbox(g, h.id);
                scope.group_pushed = true;
            }
            self.paintMouseListeners(h, st, window, cx);
            self.paintScrollListener(h, scope.style, st, window);
        }
        self.paintKeyboardListeners(window);
        return scope;
    }

    pub fn paintEnd(self: *Interactivity, scope: *const PaintScope, window: *Window) void {
        if (scope.hidden) return;
        if (scope.group_pushed) window.popGroupHitbox(self.group.?);
        window.endTabGroup(scope.tab_group);
        window.popContentMask(scope.mask);
        window.popTextStyle(scope.text);
        window.paintStyleBorder(scope.style, scope.bounds);
        window.popOpacity(scope.opacity);
    }

    fn paintHoverGroupHandler(self: *const Interactivity, window: *Window) void {
        const gh = self.group_hover_style orelse return;
        const group_hitbox = window.groupHitbox(gh.group) orelse return;
        const Ctx = struct { hitbox: HitboxId, was: bool, view: EntityId };
        window.onMouseEvent(input.MouseMoveEvent, Ctx{ .hitbox = group_hitbox, .was = group_hitbox.isHovered(window), .view = window.currentView() }, struct {
            fn f(c: *Ctx, _: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                if (phase == .capture and c.hitbox.isHovered(w) != c.was) a.notify(c.view);
            }
        }.f);
    }

    fn paintMouseListeners(self: *Interactivity, hitbox: Hitbox, st: ?*InteractiveElementState, window: *Window, cx: *App) void {
        const is_focused = if (self.tracked_focus_handle) |fh| fh.isFocused(window) else false;

        // Focus on mouse down (bubble; parents yield via preventDefault).
        if (self.tracked_focus_handle) |fh| {
            const Ctx = struct { hitbox: HitboxId, handle: FocusHandle };
            window.onMouseEvent(input.MouseDownEvent, Ctx{ .hitbox = hitbox.id, .handle = fh }, struct {
                fn f(c: *Ctx, _: *const input.MouseDownEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                    if (phase == .bubble and c.hitbox.isHovered(w) and !w.default_prevented) {
                        w.focus(c.handle);
                        w.preventDefault();
                    }
                }
            }.f);
        }

        registerMouseEntries(input.MouseDownEvent, self.mouse_down_listeners.items, hitbox, window);
        registerMouseEntries(input.MouseUpEvent, self.mouse_up_listeners.items, hitbox, window);
        registerMouseEntries(input.MouseMoveEvent, self.mouse_move_listeners.items, hitbox, window);
        registerMouseEntries(input.MouseExitEvent, self.mouse_exit_listeners.items, hitbox, window);
        registerMouseEntries(input.ScrollWheelEvent, self.scroll_wheel_listeners.items, hitbox, window);
        for (self.drag_move_listeners.items) |e| e.register(window, e.listener, hitbox);

        // Hover style tracking: re-render the view when the hover state changes.
        if (self.hover_style != null) {
            if (st) |s| {
                const Ctx = struct { hitbox: HitboxId, state: *InteractiveElementState, view: EntityId };
                window.onMouseEvent(input.MouseMoveEvent, Ctx{ .hitbox = hitbox.id, .state = s, .view = window.currentView() }, struct {
                    fn f(c: *Ctx, _: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                        const hovered = c.hitbox.isHovered(w);
                        if (phase == .capture and hovered != c.state.hover_state.element) {
                            c.state.hover_state.element = hovered;
                            a.notify(c.view);
                        }
                    }
                }.f);
            } else {
                // No id (gpui needs one here): compare against the hover state at paint time.
                const Ctx = struct { hitbox: HitboxId, was: bool, view: EntityId };
                window.onMouseEvent(input.MouseMoveEvent, Ctx{ .hitbox = hitbox.id, .was = hitbox.isHovered(window), .view = window.currentView() }, struct {
                    fn f(c: *Ctx, _: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                        if (phase == .capture and c.hitbox.isHovered(w) != c.was) {
                            c.was = !c.was;
                            a.notify(c.view);
                        }
                    }
                }.f);
            }
        }

        if (self.group_hover_style) |gh| if (window.groupHitbox(gh.group)) |group_id| if (st) |s| {
            const Ctx = struct { group: HitboxId, state: *InteractiveElementState, view: EntityId };
            window.onMouseEvent(input.MouseMoveEvent, Ctx{ .group = group_id, .state = s, .view = window.currentView() }, struct {
                fn f(c: *Ctx, _: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    const gh2 = c.group.isHovered(w);
                    if (phase == .capture and gh2 != c.state.hover_state.group) {
                        c.state.hover_state.group = gh2;
                        a.notify(c.view);
                    }
                }
            }.f);
        };

        if (self.drop_listeners.items.len > 0) {
            // Drop listeners are copied into the element state when there is one; otherwise
            // (no id) they ride in the listener captures, one listener per entry.
            for (self.drop_listeners.items) |entry| {
                const Ctx = struct { hitbox: HitboxId, entry: DropEntry, can_drop: ?*const fn (*const anyopaque, TypeId, *Window, *App) bool };
                window.onMouseEvent(input.MouseUpEvent, Ctx{ .hitbox = hitbox.id, .entry = entry, .can_drop = self.can_drop }, struct {
                    fn f(c: *Ctx, _: *const input.MouseUpEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                        if (phase != .bubble or !c.hitbox.isHovered(w)) return;
                        const drag = a.active_drag orelse return;
                        if (drag.type_id != c.entry.type_id) return;
                        if (c.can_drop) |pred| if (!pred(drag.value, drag.type_id, w, a)) return;
                        c.entry.call(c.entry.listener, drag.value, w, a);
                        a.cancelDrag();
                        w.refresh();
                        a.propagate_event = false;
                    }
                }.f);
            }
        }

        const s = st orelse return;
        s.click_listeners.clearRetainingCapacity();
        s.click_listeners.appendSlice(cx.gpa, self.click_listeners.items) catch @panic("OOM");
        s.aux_click_listeners.clearRetainingCapacity();
        s.aux_click_listeners.appendSlice(cx.gpa, self.aux_click_listeners.items) catch @panic("OOM");
        s.setDrag(cx.gpa, self.drag, self.base_style.mouse_cursor);
        s.hover_listener = self.hover_listener;
        s.tooltip_builder = self.tooltip;
        s.tooltip_source_bounds = hitbox.bounds;
        const SCtx = struct { hitbox: Hitbox, state: *InteractiveElementState, view: EntityId };
        const sctx: SCtx = .{ .hitbox = hitbox, .state = s, .view = window.currentView() };

        if (self.click_listeners.items.len > 0 or self.aux_click_listeners.items.len > 0 or self.drag != null) {
            window.onMouseEvent(input.MouseDownEvent, sctx, struct {
                fn f(c: *SCtx, ev: *const input.MouseDownEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                    if (phase == .bubble and (ev.button == .left or c.state.aux_click_listeners.items.len > 0) and c.hitbox.isHovered(w)) {
                        c.state.pending_mouse_down = ev.*;
                        w.refresh();
                    }
                }
            }.f);
            window.onMouseEvent(input.MouseMoveEvent, sctx, struct {
                fn f(c: *SCtx, ev: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase == .capture) return;
                    const down = c.state.pending_mouse_down orelse return;
                    if (a.hasActiveDrag() or down.button != .left) return;
                    const d = ev.position.sub(down.position);
                    if (@sqrt(d.x * d.x + d.y * d.y) <= events.drag_threshold) return;
                    const drag = c.state.drag orelse return;
                    c.state.clicked_state = .{};
                    const offset = ev.position.sub(c.hitbox.bounds.origin);
                    const view = drag.build(drag.value.ptr, offset, w, a);
                    const storage = a.gpa.alignedAlloc(u8, .@"16", drag.value.len) catch @panic("OOM");
                    @memcpy(storage, drag.value);
                    a.cancelDrag();
                    a.active_drag = .{
                        .value = storage.ptr,
                        .storage = storage,
                        .type_id = drag.type_id,
                        .view = view,
                        .cursor_offset = offset,
                        .cursor_style = drag.cursor_style,
                    };
                    c.state.pending_mouse_down = null;
                    w.refresh();
                    a.propagate_event = false;
                }
            }.f);
            if (is_focused) {
                window.onKeyEvent(input.KeyDownEvent, sctx, struct {
                    fn f(c: *const SCtx, ev: *const input.KeyDownEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                        if (phase != .bubble or w.default_prevented) return;
                        const k = ev.keystroke;
                        const activation = (std.mem.eql(u8, k.key, "enter") or std.mem.eql(u8, k.key, "space")) and !modified(k.modifiers);
                        c.state.pending_keyboard_down = if (activation) w.focus_generation else null;
                    }
                }.f);
                window.onKeyEvent(input.KeyUpEvent, sctx, struct {
                    fn f(c: *const SCtx, ev: *const input.KeyUpEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                        if (phase != .bubble or w.default_prevented) return;
                        const k = ev.keystroke;
                        const button: ?events.KeyboardButton = if (std.mem.eql(u8, k.key, "enter")) .enter else if (std.mem.eql(u8, k.key, "space")) .space else null;
                        if (button != null and !modified(k.modifiers)) {
                            const pending = c.state.pending_keyboard_down;
                            c.state.pending_keyboard_down = null;
                            if (pending != w.focus_generation) return;
                            const click: ClickEvent = .{ .keyboard = .{ .button = button.?, .bounds = c.hitbox.bounds } };
                            fireClick(c.state, &click, false, w, a);
                        } else c.state.pending_keyboard_down = null;
                    }
                }.f);
            }
            window.onMouseEvent(input.MouseUpEvent, sctx, struct {
                fn f(c: *SCtx, ev: *const input.MouseUpEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    switch (phase) {
                        .capture => {
                            if (c.state.pending_mouse_down != null) {
                                if (c.hitbox.isHovered(w)) c.state.captured_mouse_down = c.state.pending_mouse_down;
                                c.state.pending_mouse_down = null;
                                w.refresh();
                            }
                        },
                        .bubble => {
                            const down = c.state.captured_mouse_down orelse return;
                            c.state.captured_mouse_down = null;
                            const click: ClickEvent = .{ .mouse = .{ .down = down, .up = ev.*, .bounds = c.hitbox.bounds } };
                            fireClick(c.state, &click, down.button != .left, w, a);
                        },
                    }
                }
            }.f);
        }

        if (self.hover_listener != null) {
            window.onMouseEvent(input.MouseMoveEvent, sctx, struct {
                fn f(c: *SCtx, _: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase != .bubble) return;
                    const hovered = c.state.pending_mouse_down == null and !a.hasActiveDrag() and c.hitbox.isHovered(w);
                    updateHover(c.state, hovered, w, a);
                }
            }.f);
            window.onMouseEvent(input.MouseExitEvent, sctx, struct {
                fn f(c: *SCtx, _: *const input.MouseExitEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase == .bubble) updateHover(c.state, false, w, a);
                }
            }.f);
        }

        if (self.tooltip != null) registerTooltipHandlers(s, self.tooltip_id, self.tooltip_show_delay_ns orelse events.tooltip_show_delay_ns, hitbox, window);

        // Active (pressed) state; always bound because a mouse up may arrive before a redraw.
        const ACtx = struct { hitbox: HitboxId, state: *InteractiveElementState, group: ?HitboxId };
        const actx: ACtx = .{ .hitbox = hitbox.id, .state = s, .group = if (self.group_active_style) |g| window.groupHitbox(g.group) else null };
        window.onMouseEvent(input.MouseUpEvent, actx, struct {
            fn f(c: *ACtx, _: *const input.MouseUpEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                if (phase == .capture and (c.state.clicked_state.group or c.state.clicked_state.element)) {
                    c.state.clicked_state = .{};
                    w.refresh();
                }
            }
        }.f);
        window.onMouseEvent(input.MouseDownEvent, actx, struct {
            fn f(c: *ACtx, _: *const input.MouseDownEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                if (phase != .bubble or w.default_prevented) return;
                const group_hovered = if (c.group) |g| g.isHovered(w) else false;
                const element_hovered = c.hitbox.isHovered(w);
                if (group_hovered or element_hovered) {
                    c.state.clicked_state = .{ .group = group_hovered, .element = element_hovered };
                    w.refresh();
                }
            }
        }.f);
    }

    fn paintScrollListener(self: *const Interactivity, hitbox: Hitbox, s: *const Style, st: ?*InteractiveElementState, window: *Window) void {
        if (self.scroll_offset == null) return;
        const state = st orelse return;
        const Ctx = struct {
            hitbox: HitboxId,
            state: *InteractiveElementState,
            view: EntityId,
            overflow_x: style_mod.Overflow,
            overflow_y: style_mod.Overflow,
            allow_concurrent: bool,
            restrict_axis: bool,
            line_height: Pixels,
        };
        window.onMouseEvent(input.ScrollWheelEvent, Ctx{
            .hitbox = hitbox.id,
            .state = state,
            .view = window.currentView(),
            .overflow_x = s.overflow.x,
            .overflow_y = s.overflow.y,
            .allow_concurrent = s.allow_concurrent_scroll,
            .restrict_axis = s.restrict_scroll_to_axis,
            .line_height = window.lineHeight(),
        }, struct {
            fn f(c: *Ctx, ev: *const input.ScrollWheelEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                if (phase != .bubble or !c.hitbox.shouldHandleScroll(w)) return;
                const offset = c.state.scrollOffsetPtr();
                const old = offset.*;
                const delta: Point = switch (ev.delta) {
                    .pixels => |p| p,
                    .lines => |l| l.scale(c.line_height),
                };
                var dx: Pixels = 0;
                if (c.overflow_x == .scroll) {
                    if (delta.x != 0) dx = delta.x else if (!c.restrict_axis and c.overflow_y != .scroll) dx = delta.y;
                }
                var dy: Pixels = 0;
                if (c.overflow_y == .scroll) {
                    if (delta.y != 0) dy = delta.y else if (!c.restrict_axis and c.overflow_x != .scroll) dy = delta.x;
                }
                if (!c.allow_concurrent and dx != 0 and dy != 0) {
                    if (@abs(dx) > @abs(dy)) dy = 0 else dx = 0;
                }
                offset.x += dx;
                offset.y += dy;
                if (offset.x != old.x or offset.y != old.y) a.notify(c.view);
            }
        }.f);
    }

    fn paintKeyboardListeners(self: *Interactivity, window: *Window) void {
        if (self.key_context) |kc| switch (kc) {
            .parsed => |c| window.setKeyContext(c),
            .source => |src| if (window.internKeyContext(src)) |c| window.setKeyContext(c) else |err| {
                std.log.err("invalid key context \"{s}\": {t}", .{ src, err });
            },
        };
        for (self.key_down_listeners.items) |e| {
            window.onKeyEvent(input.KeyDownEvent, e, struct {
                fn f(c: *const KeyEntry(input.KeyDownEvent), ev: *const input.KeyDownEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase == c.phase) c.listener.callIn(ev, w, a);
                }
            }.f);
        }
        for (self.key_up_listeners.items) |e| {
            window.onKeyEvent(input.KeyUpEvent, e, struct {
                fn f(c: *const KeyEntry(input.KeyUpEvent), ev: *const input.KeyUpEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase == c.phase) c.listener.callIn(ev, w, a);
                }
            }.f);
        }
        for (self.modifiers_changed_listeners.items) |l| {
            window.onModifiersChanged(l, struct {
                fn f(c: *const Listener(input.ModifiersChangedEvent), ev: *const input.ModifiersChangedEvent, w: *Window, a: *App) void {
                    c.callIn(ev, w, a);
                }
            }.f);
        }
        for (self.action_listeners.items) |e| e.register(window, e.listener, e.phase);
    }
};

fn modified(m: input.Modifiers) bool {
    return m.control or m.alt or m.shift or m.platform or m.function;
}

fn fireClick(state: *InteractiveElementState, click: *const ClickEvent, aux: bool, w: *Window, a: *App) void {
    // Copy: listeners may re-render and replace the lists.
    const list = if (aux) state.aux_click_listeners.items else state.click_listeners.items;
    var buf: [8]Listener(ClickEvent) = undefined;
    const n = @min(list.len, buf.len);
    @memcpy(buf[0..n], list[0..n]);
    for (buf[0..n]) |*l| l.callIn(click, w, a);
}

fn updateHover(state: *InteractiveElementState, hovered: bool, w: *Window, a: *App) void {
    if (hovered == state.hover_listener_state) return;
    state.hover_listener_state = hovered;
    if (state.hover_listener) |l| l.callIn(&hovered, w, a);
}

fn registerMouseEntries(comptime Ev: type, entries: []const MouseEntry(Ev), hitbox: Hitbox, window: *Window) void {
    const Ctx = struct { entry: MouseEntry(Ev), hitbox: Hitbox };
    for (entries) |e| {
        window.onMouseEvent(Ev, Ctx{ .entry = e, .hitbox = hitbox }, struct {
            fn f(c: *Ctx, ev: *const Ev, phase: DispatchPhase, w: *Window, a: *App) void {
                const fire = switch (c.entry.mode) {
                    .bubble_button => |b| phase == .bubble and buttonOf(Ev, ev) == b and c.hitbox.isHovered(w),
                    .bubble_any => phase == .bubble and c.hitbox.isHovered(w),
                    .capture_any => phase == .capture and c.hitbox.isHovered(w),
                    .out_any => phase == .capture and !c.hitbox.contains(w.mouse_position),
                    .out_button => |b| phase == .capture and buttonOf(Ev, ev) == b and !c.hitbox.isHovered(w),
                    .scroll => phase == .bubble and c.hitbox.shouldHandleScroll(w),
                };
                if (fire) c.entry.listener.callIn(ev, w, a);
            }
        }.f);
    }
}

fn buttonOf(comptime Ev: type, ev: *const Ev) ?input.MouseButton {
    return if (@hasField(Ev, "button")) ev.button else null;
}

// ---------------------------------------------------------------------------------------
// Tooltips (gpui `register_tooltip_mouse_handlers` and friends)
// ---------------------------------------------------------------------------------------

pub const ActiveTooltip = union(enum) {
    waiting_for_show: executor.Task(void),
    visible: struct { view: AnyView, hoverable: bool, mouse_position: Point },
    waiting_for_hide: struct { view: AnyView, mouse_position: Point, task: executor.Task(void) },
};

fn tooltipOnWindow(state: *InteractiveElementState, at: *ActiveTooltip, window: *Window) ?u64 {
    const v, const pos = switch (at.*) {
        .waiting_for_show => return null,
        .visible => |vis| .{ vis.view, vis.mouse_position },
        .waiting_for_hide => |h| .{ h.view, h.mouse_position },
    };
    return window.setTooltip(.{ .id = 0, .view = v, .mouse_position = pos, .owner = state, .check_visible = checkTooltipVisible });
}

fn checkTooltipVisible(owner: *anyopaque, tooltip_bounds: Bounds, window: *Window) bool {
    const s: *InteractiveElementState = @ptrCast(@alignCast(owner));
    const at = &(s.active_tooltip orelse return false);
    const hoverable = switch (at.*) {
        .visible => |v| v.hoverable,
        .waiting_for_hide => true,
        .waiting_for_show => return false,
    };
    const hovered = s.hoveredDuringPrepaint(window) or (hoverable and tooltip_bounds.contains(window.mouse_position));
    switch (at.*) {
        .visible => |v| if (!hovered) {
            if (v.hoverable) {
                const task = window.app.foregroundExecutor().timer(events.hoverable_tooltip_hide_delay_ns, HideTooltip{ .state = s, .app = window.app, .window = window.id }) catch @panic("OOM");
                at.* = .{ .waiting_for_hide = .{ .view = v.view, .mouse_position = v.mouse_position, .task = task } };
            } else {
                s.clearTooltip(window, window.app);
            }
        },
        .waiting_for_hide => |h| if (hovered) {
            var t = h.task;
            t.cancel();
            at.* = .{ .visible = .{ .view = h.view, .hoverable = true, .mouse_position = h.mouse_position } };
        },
        .waiting_for_show => {},
    }
    return s.active_tooltip != null;
}

const ShowTooltip = struct {
    state: *InteractiveElementState,
    app: *App,
    window: window_mod.WindowId,

    pub fn finish(self: *ShowTooltip) void {
        const s = self.state;
        const w = self.app.windowById(self.window) orelse return;
        const builder = s.tooltip_builder orelse return;
        if (s.active_tooltip) |*at| if (at.* == .waiting_for_show) at.waiting_for_show.detach();
        self.app.startUpdate();
        defer self.app.finishUpdate();
        const view = builder.func(&builder.data, w, self.app);
        s.active_tooltip = .{ .visible = .{ .view = view, .hoverable = builder.hoverable, .mouse_position = w.mouse_position } };
        w.refresh();
    }
};

const HideTooltip = struct {
    state: *InteractiveElementState,
    app: *App,
    window: window_mod.WindowId,

    pub fn finish(self: *HideTooltip) void {
        const s = self.state;
        const at = &(s.active_tooltip orelse return);
        if (at.* != .waiting_for_hide) return;
        at.waiting_for_hide.task.detach();
        const w = self.app.windowById(self.window) orelse return;
        self.app.startUpdate();
        defer self.app.finishUpdate();
        s.clearTooltip(w, self.app);
    }
};

fn registerTooltipHandlers(s: *InteractiveElementState, tooltip_id: ?u64, show_delay_ns: u64, hitbox: Hitbox, window: *Window) void {
    const Ctx = struct { state: *InteractiveElementState, hitbox: HitboxId, tooltip_id: ?u64, delay: u64, view: EntityId };
    const ctx: Ctx = .{ .state = s, .hitbox = hitbox.id, .tooltip_id = tooltip_id, .delay = show_delay_ns, .view = window.currentView() };
    window.onMouseEvent(input.MouseMoveEvent, ctx, struct {
        fn f(c: *Ctx, _: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
            const st = c.state;
            const hovered = st.pending_mouse_down == null and c.hitbox.isHovered(w);
            const tooltip_hovered = tooltipHovered(w, c.tooltip_id);
            if (st.active_tooltip) |*at| switch (at.*) {
                .waiting_for_show => if (!hovered) st.clearTooltip(w, a),
                .visible => |v| if (phase == .capture and !hovered and (!v.hoverable or !tooltip_hovered)) a.notify(c.view),
                .waiting_for_hide => if (phase == .capture and (hovered or tooltip_hovered)) a.notify(c.view),
            } else if (hovered and phase == .bubble) {
                const task = a.foregroundExecutor().timer(c.delay, ShowTooltip{ .state = st, .app = a, .window = w.id }) catch @panic("OOM");
                st.active_tooltip = .{ .waiting_for_show = task };
            }
        }
    }.f);
    window.onMouseEvent(input.MouseDownEvent, ctx, struct {
        fn f(c: *Ctx, _: *const input.MouseDownEvent, _: DispatchPhase, w: *Window, a: *App) void {
            if (!tooltipHovered(w, c.tooltip_id)) c.state.clearTooltipIfNotHoverable(w, a);
        }
    }.f);
    window.onMouseEvent(input.ScrollWheelEvent, ctx, struct {
        fn f(c: *Ctx, _: *const input.ScrollWheelEvent, _: DispatchPhase, w: *Window, a: *App) void {
            if (!tooltipHovered(w, c.tooltip_id)) c.state.clearTooltipIfNotHoverable(w, a);
        }
    }.f);
}

fn tooltipHovered(w: *const Window, tooltip_id: ?u64) bool {
    const id = tooltip_id orelse return false;
    const tb = w.tooltip_bounds orelse return false;
    return tb.id == id and tb.bounds.contains(w.mouse_position);
}

// ---------------------------------------------------------------------------------------
// Element state
// ---------------------------------------------------------------------------------------

pub const ElementClickedState = struct { group: bool = false, element: bool = false };
pub const ElementHoverState = struct { group: bool = false, element: bool = false };

/// Drag spec copied into element state so it outlives the frame arena.
const StoredDrag = struct {
    type_id: TypeId,
    value: []align(16) u8,
    build: *const fn (value: *const anyopaque, offset: Point, window: *Window, app: *App) AnyView,
    cursor_style: ?platform.CursorStyle,
};

/// Per-element state of interactive divs (gpui `InteractiveElementState`).
pub const InteractiveElementState = struct {
    focus_handle: ?FocusHandle = null,
    clicked_state: ElementClickedState = .{},
    hover_state: ElementHoverState = .{},
    hover_listener_state: bool = false,
    pending_mouse_down: ?input.MouseDownEvent = null,
    captured_mouse_down: ?input.MouseDownEvent = null,
    pending_keyboard_down: ?u64 = null,
    scroll_offset: Point = .zero,
    scroll_handle: ?ScrollHandle = null,
    active_tooltip: ?ActiveTooltip = null,
    tooltip_source_bounds: Bounds = .{ .origin = .zero, .size = .zero },
    // Copies of the latest paint's listeners.
    click_listeners: std.ArrayList(Listener(ClickEvent)) = .empty,
    aux_click_listeners: std.ArrayList(Listener(ClickEvent)) = .empty,
    hover_listener: ?Listener(bool) = null,
    tooltip_builder: ?TooltipBuilder = null,
    drag: ?StoredDrag = null,

    pub fn deinit(self: *InteractiveElementState, app: *App) void {
        if (self.focus_handle) |h| h.release(app);
        if (self.scroll_handle) |h| h.release();
        if (self.active_tooltip) |*at| releaseTooltip(at, app);
        self.click_listeners.deinit(app.gpa);
        self.aux_click_listeners.deinit(app.gpa);
        if (self.drag) |d| app.gpa.free(d.value);
    }

    fn setScrollHandle(self: *InteractiveElementState, h: ScrollHandle) void {
        if (self.scroll_handle) |old| {
            if (old.state == h.state) return;
            old.release();
        }
        self.scroll_handle = h.retain();
    }

    fn scrollOffsetPtr(self: *InteractiveElementState) *Point {
        return if (self.scroll_handle) |h| &h.state.offset else &self.scroll_offset;
    }

    fn setDrag(self: *InteractiveElementState, gpa: std.mem.Allocator, spec: ?DragSpec, cursor: ?platform.CursorStyle) void {
        const d = spec orelse {
            if (self.drag) |old| gpa.free(old.value);
            self.drag = null;
            return;
        };
        var buf: []align(16) u8 = if (self.drag) |old| old.value else &.{};
        if (buf.len != d.bytes.len) {
            if (self.drag) |old| gpa.free(old.value);
            buf = gpa.alignedAlloc(u8, .@"16", d.bytes.len) catch @panic("OOM");
        }
        @memcpy(buf, d.bytes);
        self.drag = .{ .type_id = d.type_id, .value = buf, .build = d.build, .cursor_style = cursor };
    }

    fn hoveredDuringPrepaint(self: *const InteractiveElementState, w: *const Window) bool {
        return !w.last_input_was_keyboard and self.pending_mouse_down == null and self.tooltip_source_bounds.contains(w.mouse_position);
    }

    fn clearTooltip(self: *InteractiveElementState, w: *Window, app: *App) void {
        const at = &(self.active_tooltip orelse return);
        const was_visible = at.* != .waiting_for_show;
        releaseTooltip(at, app);
        self.active_tooltip = null;
        if (was_visible) w.refresh();
    }

    fn clearTooltipIfNotHoverable(self: *InteractiveElementState, w: *Window, app: *App) void {
        const at = self.active_tooltip orelse return;
        if (at == .visible and !at.visible.hoverable) self.clearTooltip(w, app);
    }
};

fn releaseTooltip(at: *ActiveTooltip, app: *App) void {
    switch (at.*) {
        .waiting_for_show => |*t| t.cancel(),
        .visible => |v| v.view.entity.release(app),
        .waiting_for_hide => |*h| {
            h.task.cancel();
            h.view.entity.release(app);
        },
    }
}

// ---------------------------------------------------------------------------------------
// Scroll handles
// ---------------------------------------------------------------------------------------

pub const ScrollHandleState = struct {
    gpa: std.mem.Allocator,
    refs: u32 = 1,
    offset: Point = .zero,
    bounds: Bounds = .{ .origin = .zero, .size = .zero },
    max_offset: Point = .zero,
    child_bounds: std.ArrayList(Bounds) = .empty,
    scroll_to_bottom: bool = false,
    overflow: struct { x: style_mod.Overflow = .visible, y: style_mod.Overflow = .visible } = .{},
    active_item: ?struct { index: usize, top: bool } = null,
};

/// Shared scroll state of an `overflow*Scroll` div (gpui `ScrollHandle`). Reference counted:
/// create in your view with `ScrollHandle.init(cx.gpa())` and `release()` in `deinit`.
pub const ScrollHandle = struct {
    state: *ScrollHandleState,

    pub fn init(gpa: std.mem.Allocator) ScrollHandle {
        const s = gpa.create(ScrollHandleState) catch @panic("OOM");
        s.* = .{ .gpa = gpa };
        return .{ .state = s };
    }

    pub fn retain(self: ScrollHandle) ScrollHandle {
        self.state.refs += 1;
        return self;
    }

    pub fn release(self: ScrollHandle) void {
        self.state.refs -= 1;
        if (self.state.refs == 0) {
            self.state.child_bounds.deinit(self.state.gpa);
            self.state.gpa.destroy(self.state);
        }
    }

    /// Current offset (≤ 0; more negative = scrolled further).
    pub fn offset(self: ScrollHandle) Point {
        return self.state.offset;
    }
    pub fn setOffset(self: ScrollHandle, p: Point) void {
        self.state.offset = p;
    }
    pub fn maxOffset(self: ScrollHandle) Point {
        return self.state.max_offset;
    }
    pub fn bounds(self: ScrollHandle) Bounds {
        return self.state.bounds;
    }
    pub fn boundsForItem(self: ScrollHandle, ix: usize) ?Bounds {
        const cb = self.state.child_bounds.items;
        return if (ix < cb.len) cb[ix] else null;
    }
    pub fn childrenCount(self: ScrollHandle) usize {
        return self.state.child_bounds.items.len;
    }
    pub fn scrollToBottom(self: ScrollHandle) void {
        self.state.scroll_to_bottom = true;
    }
    /// Scroll minimally so child `ix` is visible on the next frame.
    pub fn scrollToItem(self: ScrollHandle, ix: usize) void {
        self.state.active_item = .{ .index = ix, .top = false };
    }
    /// Scroll so child `ix` is at the top on the next frame.
    pub fn scrollToTopOfItem(self: ScrollHandle, ix: usize) void {
        self.state.active_item = .{ .index = ix, .top = true };
    }

    /// Index of the first child scrolled into view.
    pub fn topItem(self: ScrollHandle) usize {
        const s = self.state;
        return itemAt(s.child_bounds.items, s.bounds.origin.y - s.offset.y);
    }
    pub fn bottomItem(self: ScrollHandle) usize {
        const s = self.state;
        return itemAt(s.child_bounds.items, s.bounds.bottom() - s.offset.y);
    }

    fn itemAt(cb: []const Bounds, y: Pixels) usize {
        var lo: usize = 0;
        var hi: usize = cb.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (y < cb[mid].origin.y) hi = mid else if (y > cb[mid].bottom()) lo = mid + 1 else return mid;
        }
        return @min(lo, cb.len -| 1);
    }

    fn scrollToActiveItem(self: ScrollHandle) void {
        const s = self.state;
        const item = s.active_item orelse return;
        if (item.index >= s.child_bounds.items.len) return;
        const b = s.child_bounds.items[item.index];
        if (item.top) {
            s.offset.y = s.bounds.origin.y - b.origin.y;
        } else if (s.overflow.y == .scroll) {
            if (b.size.height > s.bounds.size.height or b.origin.y + s.offset.y < s.bounds.origin.y) {
                s.offset.y = s.bounds.origin.y - b.origin.y;
            } else if (b.bottom() + s.offset.y > s.bounds.bottom()) {
                s.offset.y = s.bounds.bottom() - b.bottom();
            }
        }
        if (s.overflow.x == .scroll) {
            if (b.size.width > s.bounds.size.width or b.origin.x + s.offset.x < s.bounds.origin.x) {
                s.offset.x = s.bounds.origin.x - b.origin.x;
            } else if (b.right() + s.offset.x > s.bounds.right()) {
                s.offset.x = s.bounds.right() - b.right();
            }
        }
        s.active_item = null;
    }
};

// ---------------------------------------------------------------------------------------
// The element
// ---------------------------------------------------------------------------------------

pub const DivFrameState = struct { child_layout_ids: []LayoutId };

/// The element behind `Div`/`StatefulDiv` handles.
pub const DivElement = struct {
    d: *DivData,

    pub const RequestLayoutState = DivFrameState;
    pub const PrepaintState = ?Hitbox;

    pub fn elementId(self: *DivElement) ?ElementId {
        return self.d.interactivity.element_id;
    }

    pub fn a11yNode(self: *DivElement, gid: GlobalElementId, bounds: Bounds, window: *Window) ?a11y.NodeSpec {
        return self.d.interactivity.a11yNode(gid, bounds, window);
    }

    pub fn requestLayout(self: *DivElement, gid: ?GlobalElementId, state: *DivFrameState, window: *Window, cx: *App) LayoutId {
        const it = &self.d.interactivity;
        const s = it.requestLayoutStyle(gid, window, cx);
        const text: ?style_mod.TextStyleRefinement = if (s.textStyle()) |t| t.* else null;
        window.pushTextStyle(text);
        defer window.popTextStyle(text);
        const kids = self.d.children.slice();
        const ids = arena_mod.frameAllocator().alloc(LayoutId, kids.len) catch @panic("OOM");
        for (kids, ids) |c, *id| id.* = c.requestLayout(window, cx);
        state.* = .{ .child_layout_ids = ids };
        return window.requestLayout(s, ids);
    }

    pub fn prepaint(self: *DivElement, gid: ?GlobalElementId, bounds: Bounds, rl: *DivFrameState, hitbox: *?Hitbox, window: *Window, cx: *App) void {
        const it = &self.d.interactivity;
        var content_size = bounds.size;
        const want_child_bounds = self.d.children_prepainted != null;
        var child_bounds: std.ArrayList(Bounds) = .empty;
        if (rl.child_layout_ids.len > 0) {
            var min: Point = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
            var max: Point = .zero;
            const tracked = it.tracked_scroll_handle;
            if (tracked) |h| h.state.child_bounds.clearRetainingCapacity();
            for (rl.child_layout_ids) |id| {
                const b = window.layoutBounds(id);
                min = .{ .x = @min(min.x, b.origin.x), .y = @min(min.y, b.origin.y) };
                max = .{ .x = @max(max.x, b.right()), .y = @max(max.y, b.bottom()) };
                if (tracked) |h| h.state.child_bounds.append(h.state.gpa, b) catch @panic("OOM");
                if (want_child_bounds) child_bounds.append(arena_mod.frameAllocator(), b) catch @panic("OOM");
            }
            content_size = .{ .width = max.x - min.x, .height = max.y - min.y };
            if (tracked) |h| h.scrollToActiveItem();
        }
        const scope = it.prepaintBegin(gid, bounds, content_size, window, cx);
        defer it.prepaintEnd(&scope, window);
        hitbox.* = scope.hitbox;
        if (scope.style.display == .none) return;
        window.pushElementOffset(scope.scroll_offset);
        for (self.d.children.slice()) |c| c.prepaint(window, cx);
        window.popElementOffset();
        if (self.d.children_prepainted) |l| {
            const slice: []const Bounds = child_bounds.items;
            l.callIn(&slice, window, cx);
        }
    }

    pub fn paint(self: *DivElement, gid: ?GlobalElementId, bounds: Bounds, _: *DivFrameState, hitbox: *?Hitbox, window: *Window, cx: *App) void {
        const it = &self.d.interactivity;
        const scope = it.paintBegin(gid, bounds, hitbox.*, window, cx);
        defer it.paintEnd(&scope, window);
        if (scope.hidden or scope.style.display == .none) return;
        for (self.d.children.slice()) |c| c.paint(window, cx);
    }
};

comptime {
    styled.assertStyled(Div);
    styled.assertStyled(StatefulDiv);
}
