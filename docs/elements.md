# Windows, views and elements (`src/window/`, `src/elements/`)

How to write UI in zpui. This is a port of gpui's `Window` / `Element` / `Div` layer
(zui `window.rs`, `element.rs`, `view.rs`, `elements/*.rs`); if you know gpui, the concepts
map one to one and the differences are listed at the end. The reactive core underneath
(App, Entity, Context, effects, actions, keymap) is described in [core-model.md](core-model.md).

```zig
const zpui = @import("zpui");
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init; // for hover/active/focus refinements
```

## 1. A complete app

```zig
const Increment = zpui.action("counter::Increment");

const Counter = struct {
    count: u32 = 0,
    focus: zpui.FocusHandle,

    // Root views are built with the window: `init(args..., window, cx)`.
    fn init(window: *zpui.Window, cx: *zpui.Context(Counter)) Counter {
        const focus = cx.focusHandle();
        window.focus(focus); // keybindings dispatch from the focused element
        return .{ .focus = focus };
    }

    pub fn deinit(self: *Counter, cx: *zpui.App) void {
        self.focus.release(cx);
    }

    // A view: `render(self, window, cx)` returns any element-like value.
    pub fn render(self: *Counter, _: *zpui.Window, cx: *zpui.Context(Counter)) zpui.Div {
        return div()
            .trackFocus(self.focus).keyContext("Counter")
            .onAction(Increment, cx.listener(Counter.increment))
            .sizeFull().flex().flexCol().gap2().p4().bg(zpui.color.white)
            .child(zpui.fmt("Count: {d}", .{self.count}))
            .child(div().id("inc").px3().py1().roundedMd().bg(blue).cursorPointer()
                .hover(sb.bg(light_blue)).active(sb.bg(dark_blue))
                .onClick(cx.listener(Counter.onClick))
                .child("Increment"));
    }

    fn onClick(self: *Counter, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *zpui.Context(Counter)) void {
        self.count += 1;
        cx.notify(); // re-render the window(s) showing this view
    }

    fn increment(self: *Counter, _: *const Increment, _: *zpui.Window, cx: *zpui.Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }
};

fn onLaunch(_: void, app: *zpui.App) void {
    app.addFont(geist_regular_ttf) catch {};
    app.bindKeys(&.{ .init("secondary-=", Increment{}, "Counter") }) catch {};
    _ = app.openWindow(.{
        .bounds = .{ .origin = .zero, .size = .{ .width = 640, .height = 400 } },
        .titlebar = .{ .title = "Counter" },
    }, Counter, Counter.init, .{}) catch return;
}

pub fn main(init: std.process.Init) !void {
    const plat = try zpui.linux_platform.create(init.gpa, .{ .io = init.io });
    const app = try zpui.App.init(init.gpa, plat);
    defer app.deinit();
    app.run({}, onLaunch);
}
```

`examples/hello.zig` (`zig build hello`) is a fuller version of this.

## 2. Views, components, elements

| kind | what it is | how it is used |
|---|---|---|
| **view** | an entity type with `pub fn render(self: *V, window: *Window, cx: *Context(V)) R` | `div().child(self.sidebar)` where `sidebar: Entity(Sidebar)`; window roots |
| **component** (gpui `RenderOnce`) | a plain struct with `pub fn render(self: C, window: *Window, cx: *App) R` | `div().child(Button{ .label = "Save" })` |
| **element** | implements the element protocol (§9) | `div()`, text, `canvas`, `img`, ... |

`R` may be any element-like type: `Div`, `StatefulDiv`, `AnyElement`, a string, a view
entity, a component. When a function needs to return different element types, convert with
`zpui.intoAnyElement(x)` and return `zpui.AnyElement`.

Things accepted by `.child(...)` / `.children(...)`: elements, `Div`s, strings
(`[]const u8`, literals), `Entity(V)` of a view, `AnyView`, components, `AnyElement`,
and optionals of all those (`null` adds an empty element, handy for conditionals).
`.children(.{ a, b, c })` takes a tuple or a slice.

**Strings must outlive the frame**: literals, data owned by your view, or
`zpui.fmt("{d} items", .{n})` which allocates in the frame arena.

### Rendering and invalidation

* `cx.notify()` marks the view's entity changed. Every window that read it during its last
  draw (rendered it, or `read`/`update`d it from render) redraws on the next frame; the
  App's observers run as usual. Notifying entities a window never touched redraws nothing.
* All views in a window re-render on every redraw (gpui semantics), **unless** a view is
  cached: `div().child(self.sidebar.cached(sb.sizeFull().refinement))`. A cached view skips render, layout,
  prepaint and paint when neither it nor anything it read was notified and its bounds are
  unchanged; the previous frame's scene ranges, hitboxes, listeners, dispatch nodes,
  element state and text layouts are reused. Cache big, stable subtrees (sidebars, panes,
  long lists).
* `window.refresh()` redraws everything without cache reuse.
* `window.requestAnimationFrame()` re-renders the current view next frame (animations).

### Window API (selection)

`window.viewportSize()`, `scaleFactor()`, `windowAppearance()`, `isWindowActive()`,
`setTitle()`, `setBackgroundAppearance()`, `removeWindow()`, `prefersReducedMotion()`,
`mousePosition()`, `currentModifiers()`, `focus(handle)`, `blur()`, `focusNext()`,
`focusPrev()`, `dispatchAction(A{})`, `isActionAvailable(A)`, `onNextFrame(ctx, f)`,
`setRemSize()`, `textStyle()`, `lineHeight()`.
`WindowHandle(V)` (from `app.openWindow`) has `update(app, f, args)` →
`f(root: *V, args..., window, cx)`, `window(app)` and `rootView(app)`.

## 3. `div()`

`div()` returns a `Div`: a one-pointer handle to arena data, so builder chains are cheap.
`.id(x)` (`x`: string, integer, `.{ "row", ix }` tuple) returns a `StatefulDiv` — gpui's
`Stateful<Div>` — which additionally allows `onClick`, `onAuxClick`, `active`,
`groupActive`, `onDrag`, `onHover`, `tooltip`, `focusable`; calling those on a plain `Div`
is a compile error telling you to add an id. Ids only need to be unique among siblings
(their path from the root is hashed into a `GlobalElementId`).

### Styling

All of gpui's `Styled` methods exist in camelCase (generated, ~2.3k methods):
`flex flexCol flexRow flex1 flexNone gap2 gap(px(6)) itemsCenter justifyBetween`
`p4 px(px(12)) py2 m2 mxAuto w(px(100)) wFull sizeFull minW0 h8 size4`
`absolute relative top(px(0)) inset0` `bg(color) textColor(c) textSm textXs text2xl`
`textSize(px(13)) fontWeight(600) fontFamily("Geist") lineHeight(px(20)) italic underline`
`border1 borderT2 borderColor(c) borderDashed rounded roundedMd roundedLg roundedFull`
`shadowSm shadowMd shadowLg shadow(&list) opacity(0.5) overflowHidden truncate lineClamp(2)`
`cursorPointer cursorText hidden visible` … (see `src/styled.zig`, `src/style/styled_generated.zig`).
Lengths accept `px(v)`, plain numbers (pixels), `zpui.rems(v)`, `zpui.relative(0.5)`, `.auto`.

* `.when(cond, Div.bg, .{c})` applies a builder method conditionally (`StatefulDiv.bg`
  for stateful divs).
* `.refineStyle(sb.bg(c).p2())` / `.refineStyleIf(cond, ...)` merge a whole refinement.
* Text style properties (`textColor`, `textSize`, `fontFamily`, `fontWeight`, alignment,
  truncation) are inherited by all descendants.

### Interaction styles

```zig
div().id("row")
    .hover(sb.bg(theme.hover))               // mouse over (works without id too)
    .active(sb.bg(theme.pressed))            // pressed (needs id)
    .group("row")                            // name a group…
    .child(div().groupHover("row", sb.textColor(theme.fg)))   // …style children on group hover
    .trackFocus(self.focus).focusStyle(sb.borderColor(theme.ring))
    .inFocus(sb.bg(theme.focused_bg))        // focus is inside
    .focusVisible(sb.shadow(&ring))          // focused via keyboard
    .dragOver(Card, sb.bg(theme.drop))       // a drag of type Card hovers this
```

Hover styles are suppressed while the user is typing (keyboard modality), as in gpui.

### Listeners

Every listener argument accepts either `cx.listener(Self.method)` or a plain function.

```zig
// Method listeners (the entity is held weakly; window param optional):
fn onSave(self: *Editor, ev: *const zpui.ClickEvent, window: *zpui.Window, cx: *zpui.Context(Editor)) void
fn onSave(self: *Editor, ev: *const zpui.ClickEvent, cx: *zpui.Context(Editor)) void

// With up to 24 bytes of captured data (gpui's `move |..| this.select(ix)`):
.onClick(cx.listenerWith(ix, Self.select))
fn select(self: *List, ix: usize, ev: *const zpui.ClickEvent, window: *zpui.Window, cx: *zpui.Context(List)) void

// Free functions:
fn logDown(ev: *const zpui.input.MouseDownEvent, window: *zpui.Window, cx: *zpui.App) void
```

| method | event / notes |
|---|---|
| `onClick`, `onAuxClick` (id) | `ClickEvent` (`.mouse` / `.keyboard` (enter/space on focused element)); `clickCount()`, `modifiers()`, `isRightClick()` |
| `onMouseDown(button, l)`, `onAnyMouseDown`, `captureAnyMouseDown`, `onMouseDownOut` | `input.MouseDownEvent` |
| `onMouseUp(button, l)`, `onAnyMouseUp`, `captureAnyMouseUp`, `onMouseUpOut(button, l)` | `input.MouseUpEvent` |
| `onMouseMove`, `onMouseExit`, `onScrollWheel` | `MouseMoveEvent`, `MouseExitEvent`, `ScrollWheelEvent` |
| `onHover(l)` (id) | `bool` — hover started/ended |
| `onKeyDown`, `captureKeyDown`, `onKeyUp`, `captureKeyUp`, `onModifiersChanged` | key events on the focus path |
| `onAction(A, l)`, `captureAction(A, l)` | action `A` dispatched from the focus path |
| `onDrag(value, build)` (id) | starts a drag of `value` past the 2px threshold; `build(*const T, offset, window, app) Entity(W)` returns the preview view |
| `onDrop(T, l)`, `canDrop(f)`, `onDragMove(T, l)` | typed drop target (`l` gets `*const T`), predicate, `DragMoveEvent(T)` |
| `tooltip(build)`, `tooltipWith(data, build)`, `hoverableTooltip`, `tooltipShowDelay(ns)` (id) | `build([data,] window, app) Entity(W)` after 500 ms hover |
| `occlude()`, `blockMouseExceptScroll()` | stop mouse events reaching elements behind |
| `onChildrenPrepainted(l)` | `[]const Bounds` of the children |

Dispatch order is gpui's: mouse capture runs back-to-front (parents first), bubble
front-to-back; `cx.stopPropagation()` (or `app.propagate_event = false`) ends it;
`window.preventDefault()` stops ancestors from taking focus on mouse down.
Action bubble listeners stop propagation by default; call `cx.propagate()` to continue.

### Focus and keyboard

```zig
self.focus = cx.focusHandle().tabStop(true).tabIndex(1); // keep it; release in deinit
div().trackFocus(self.focus)          // click focuses it; focus styles; key dispatch target
div().id("x").focusable()             // focus handle kept in element state
div().tabIndex(2).tabGroup()          // tab order (groups nest)
self.focus.isFocused(window); self.focus.containsFocused(window); self.focus.withinFocused(window)
window.focus(self.focus); window.focusNext(); window.focusPrev();
try self.subs.add(cx.gpa(), try cx.onFocus(self.focus, window, Self.focused)); // onBlur/onFocusIn/onFocusOut
```

Keystrokes go through the keymap first (`app.bindKeys(&.{ .init("cmd-k cmd-s", SaveAll{}, "Editor") })`,
contexts from `.keyContext("Editor mode=full")` along the focus path; multi-stroke bindings
wait for the next key with a 1 s timeout), then to `onKeyDown`/`onKeyUp` listeners
(capture root→focus, bubble focus→root). **With nothing focused, dispatch starts at the
window root only**, so give your root view a focus handle and focus it (as gpui apps do).
Global fallbacks: `app.onAction(A, ctx, f)`.

### Scrolling

```zig
self.scroll = zpui.ScrollHandle.init(cx.gpa());     // in init; self.scroll.release() in deinit
div().id("list").overflowYScroll().trackScroll(self.scroll).children(items)
self.scroll.offset(); self.scroll.scrollToItem(ix); self.scroll.scrollToBottom(); self.scroll.topItem();
```

`overflow*Scroll` needs an id (offsets live in element state); `trackScroll` is optional.

## 4. Text

Strings become text elements that wrap to the width their parent gives them and inherit
the text style. `truncate()` / `textEllipsis()` / `lineClamp(n)` / `whitespaceNowrap()`
on the parent control overflow.

```zig
zpui.styledText(self.line).withHighlights(&.{
    .{ .start = 4, .end = 9, .style = .{ .color = theme.keyword, .font_weight = 600 } },
})
zpui.InteractiveText.init("msg", zpui.styledText(text))
    .onClick(&.{ .{ 10, 24 } }, cx.listener(Self.onLink))   // fn(*Self, *const usize, ...) — range index
    .onHover(cx.listener(Self.onHoverText))                    // fn(*Self, *const ?usize, ...) — byte index
```

`StyledText.withRuns(runs)` takes explicit `zpui.text.TextRun`s; `.textLayout()` gives
`indexForPosition` / `positionForIndex` after layout.

## 5. Other elements

```zig
// Popovers: laid out in place, painted above everything (higher priority later).
zpui.deferred(zpui.anchored().position(mouse).snapToWindow().child(menu)).withPriority(1)
//   anchored: .anchorCorner(.top_right) .offset(p) .positionMode(.local) .snapToWindowWithMargin(.all(8))

// Custom painting in a styled box (ctx is copied into the frame arena):
zpui.canvas(self, Self.paintChart).sizeFull()
fn paintChart(self: *Self, bounds: zpui.Bounds(f32), window: *zpui.Window, cx: *zpui.App) void {
    window.paintQuad(zpui.fill(bounds, theme.bg).cornerRadii(4));
}

// Images (src/image decodes PNG/JPEG/GIF/WebP/SVG on a worker; window refreshes when ready):
zpui.img(zpui.ImageSource{ .image = .fromBytes(png_bytes) }).size8().roundedFull().objectFit(.cover)
zpui.img("avatars/me.png")   // asset path via zpui.images.setAssetSource(app, src)

// Monochrome icons tinted with the text color:
zpui.svg().source("close", @embedFile("close.svg")).size4().textColor(theme.muted)
zpui.svg().path("icons/close.svg")
```

## 5a. Lists, animation, scrollbars, effects

Ported from gpui `elements/{list,uniform_list,animation}.rs`, gpui-component's scrollbar
and zeron's `edge_fade.rs`/`frost.rs` (`src/elements/{list,uniform_list,animation,scrollbar,effects}.zig`;
`zig build list-demo` shows all of them together).

### `list()` — variable-height virtualized list

```zig
// view state (reference counted; release in deinit)
self.items = zpui.ListState.init(cx.gpa(), n, .bottom, px(320));  // count, alignment, overdraw
self.items.setFollowMode(.tail);           // chat: stay at the end while the user is there
// render: entity-bound callback (or `list(state, ctx_value, fn(ctx, ix, *Window, *App) R)`)
zpui.list(self.items, cx, Self.renderRow).sizeFull()
fn renderRow(self: *Chat, ix: usize, window: *Window, cx: *Context(Chat)) zpui.Div { ... }
```

Only items in the viewport plus `overdraw` px are rendered/laid out each frame; heights are
measured on demand and cached in a treap of per-item summaries (gpui's `SumTree`), so offset ↔
index, splice and remeasure are O(log n). The scroll position is logical
(`ListOffset{ item_ix, offset_in_item }`), which anchors the view when items are spliced
above it. Tell the state about data changes:

| call | when |
|---|---|
| `splice(.{ .start, .end }, new_count)` / `spliceFocusable(range, handles)` | items replaced/inserted/removed |
| `remeasureItems(range)` | an item's height changed (streaming text); keeps the pixel offset into the top item |
| `remeasure()` | everything changed height (font size); keeps the proportional offset |
| `reset(n)` / `resetWithUniformHeight(n, h)` / `withUniformItemHeight(h)` | new data; height hints size the scrollbar before measurement |
| `measureAll()` | measure every item on the first layout |

Scrolling: `scrollTo(offset)`, `scrollBy(px)`, `scrollToEnd()`, `scrollToRevealItem(ix)`,
`logicalScrollTop()`, `isScrolledToEnd()`, `isFollowingTail()`, `boundsForItem(ix)`,
`itemIsAboveViewport/BelowViewport(ix)`, `setScrollHandler(cx.listener(Self.onScroll))`
(`ListScrollEvent`), `setTailReservation(.{ .start, .inset })` (zui fork: reserve a
viewport from `start` so a just-sent message can sit at the top), scrollbar hooks
(`scrollPxOffsetForScrollbar`, `maxOffsetForScrollbar`, `setOffsetFromScrollbar`,
`scrollbarDragStarted/Ended`), diagnostics (`lastVisibleCount`, `lastRenderedCount`,
`measuredCount`). Unmeasured items without a hint count as 0px (as in gpui), so wheel
scrolling clamps to what has been measured and the scrollbar converges as you scroll.
`.withSizingBehavior(.infer)` sizes the list to its items. Children may call
`window.requestAutoscroll(bounds)` during prepaint to have the list scroll them into view.

### `uniformList()` — same-height rows

```zig
self.scroll = zpui.UniformListScrollHandle.init(cx.gpa());           // release in deinit
zpui.uniformList("files", n, cx, Self.rows).trackScroll(self.scroll).sizeFull()
fn rows(self: *Files, range: zpui.Range, window: *Window, cx: *Context(Files)) []zpui.AnyElement
self.scroll.scrollToItem(ix, .nearest);  // .top .center .bottom .nearest; *Strict / *WithOffset
```

Measures one item, renders only `range`. `.withHorizontalSizingBehavior(.unconstrained)`,
`.yFlipped(true)`, `.withDecoration(ctx, f)`, `.withWidthFromItem(ix)`.

### Animation

```zig
zpui.withAnimation(el, "fade-in", zpui.Animation.ms(500).withEasing(zpui.easing.ease_out_expo), struct {
    fn f(e: zpui.Div, t: f32) zpui.Div { return e.opacity(t).relative().top(px(4 * (1 - t))); }
}.f)
div().id("dot").withAnimation("pulse", zpui.Animation.ms(1200).repeat()
    .withEasing(zpui.easing.pulsatingBetween(0.4, 1)), Self.pulse)    // also on Div/StatefulDiv
zpui.withAnimationCtx(el, id, anim, captured, fn (C, E, f32) R)     // captured data
zpui.withAnimations(el, id, &.{ a, b }, fn (E, usize, f32) R)       // chains
```

Progress is kept in element state under the id; frames are requested with
`window.requestAnimationFrame()` until done. With `window.prefersReducedMotion()` oneshot
animations render their end state, repeating ones their start state, without frames.
Easings: `linear quadratic ease_in_out ease_out_quint bounce(e) pulsatingBetween(min,max)
cubicBezier(x1,y1,x2,y2)` (exact CSS solver) plus presets `ease css_ease_in css_ease_out
css_ease_in_out ease_out_expo standard`, and `custom(fn)`. `animation.Tween` (time-based
interpolation, e.g. scroll glides) and `animation.Spring` (per-frame damped spring) help
with hand-driven motion.

### Scrollbars

```zig
div().relative().sizeFull()
    .child(zpui.list(self.items, cx, Self.row).sizeFull())
    .child(zpui.scrollbar(self.items))          // ListState | ScrollHandle | UniformListScrollHandle
zpui.scrollbar(self.scroll).id("sb2").axis(.both).mode(.hover)
    .withStyle(.{ .thumb = fg.opacity(0.30), .thumb_hover = fg.opacity(0.42), .thumb_active = fg.opacity(0.55) })
zpui.scrollbar(self.scroll).withStyle(zpui.ScrollbarStyle.compact)   // zeron's menu bar
```

An absolutely positioned overlay filling its parent: the thumb shows while scrolling and
fades after `fade_delay_ms` (`.scrolling`), or on hover (`.hover`), or always; it widens
on hover, drags (thumb) and jumps (track click). State lives in element state under its id.

### Edge fade, frost, layers

```zig
zpui.edgeFaded(24, true, true, scroller).fadeOverflowY(self.items)   // fades only where content is hidden
    .bandTop(12).bandBottom(30).insetTop(7)   // also fadeLeft/fadeRight, fadeOverflowX, fadeScrollX, fadeLabelOverflow
zpui.frosted(12, zpui.effects.menu_blur, card)   // backdrop blur + card in one layer; .enabled(false) to pass through
zpui.layered(child)                              // a fresh draw order for overlays inside a frosted card
```

### Scrolling notes

Wheel/trackpad input arrives as `ScrollWheelEvent`s: precise pixel deltas from Wayland
finger/continuous sources and XI2 smooth-scroll valuators (fractional lines on X11), line
deltas from wheels. `list` coalesces same-direction deltas per frame (20 px per line, like
gpui). gpui implements no kinetic/momentum scrolling for desktop Linux (its momentum is only
for touch-screen pans), so neither does zpui; use `animation.Spring`/`Tween` for glides.

## 6. State that is not in your view

* **Element state** (for elements you write): `window.elementState(S, gid)` returns a
  stable `*S` kept across frames while an element with that global id is drawn; it is
  destroyed (`S.deinit(...)`) the first frame it is not. `S` must default-initialize, or use
  `elementStateInit(S, gid, value)`.
* **Keyed entity state** for components: `window.useKeyedState(S, gid, init)` returns an
  `Entity(S)` owned by the element state.

## 7. Paint API (for canvas and custom elements)

All take logical pixels, apply content mask / opacity / edge fade and snap to device
pixels: `paintQuad(PaintQuad)` (`zpui.fill`, `zpui.outline`, `zpui.quad`, `.cornerRadii`,
`.borderWidths`, `.borderColor`), `paintDropShadows` / `paintInsetShadows` / `paintShadows`,
`paintBackdropBlur(bounds, radii, blur)`, `paintPath(path, bg)`, `paintUnderline`,
`paintStrikethrough`, `paintGlyph`, `paintEmoji`, `paintSvg(bounds, path, bytes, transform, color)`,
`paintImage(bounds, radii, *RenderImage, frame, grayscale)`, `paintImageFitted(..., alpha_mask)`,
`paintStyle` / `paintStyleBorder` (a `Style`'s background/shadows and border),
`glyphPainter()` (for `ShapedLine.paint`). Scoped state uses explicit push/pop pairs
(Zig has no closures):

```zig
window.pushContentMask(.{ .bounds = clip });  defer window.popContentMask(.{ .bounds = clip });
const prev = window.pushOpacity(0.5);         defer window.popOpacity(prev);
const fade = window.pushEdgeFade(.{ .bounds = b, .band = 24, .top = true, .bottom = true }); defer window.popEdgeFade(fade);
const layer = window.pushLayer(bounds);       defer window.popLayer(layer);
window.pushTextStyle(refinement);             defer window.popTextStyle(refinement);
window.pushElementOffset(scroll);             defer window.popElementOffset();   // prepaint
```

## 8. IME / text input

A text view implements some of `selectedTextRange`, `markedTextRange`, `textForRange`,
`replaceTextInRange` (required), `replaceAndMarkTextInRange`, `unmarkText`,
`boundsForRange`, `acceptsTextInput` (see `src/window/input_handler.zig` for signatures;
ranges are UTF-16) and its element calls, during paint,
`window.handleInput(focus_handle, zpui.ElementInputHandler.init(view_entity, bounds))`.
Unhandled printable keys and platform IME events then reach the view.

## 9. Writing an element

```zig
const Swatch = struct {
    color: zpui.Hsla,
    pub const PrepaintState = zpui.Hitbox;        // optional (void); also RequestLayoutState

    pub fn elementId(self: *Swatch) ?zpui.ElementId { _ = self; return .from("swatch"); } // optional

    pub fn requestLayout(self: *Swatch, id: ?zpui.GlobalElementId, state: *void, window: *zpui.Window, cx: *zpui.App) zpui.LayoutId {
        return window.requestLayout(.{ .size = .{ .width = .{ .definite = .{ .absolute = .{ .pixels = 20 } } }, .height = .auto } }, &.{});
    }
    pub fn prepaint(self: *Swatch, id: ?zpui.GlobalElementId, bounds: zpui.Bounds(f32), rl: *void, hitbox: *zpui.Hitbox, window: *zpui.Window, cx: *zpui.App) void {
        hitbox.* = window.insertHitbox(bounds, .normal);
    }
    pub fn paint(self: *Swatch, id: ?zpui.GlobalElementId, bounds: zpui.Bounds(f32), rl: *void, hitbox: *zpui.Hitbox, window: *zpui.Window, cx: *zpui.App) void {
        window.paintQuad(zpui.fill(bounds, self.color));
        window.onMouseEvent(zpui.input.MouseDownEvent, hitbox.id, Swatch.onDown); // ctx copied inline (<=160 bytes)
    }
    fn onDown(hitbox: *zpui.window.HitboxId, ev: *const zpui.input.MouseDownEvent, phase: zpui.DispatchPhase, window: *zpui.Window, cx: *zpui.App) void { ... }
};
```

* Phases run once per frame in order request layout → prepaint → paint. Hitboxes,
  `deferDraw`, element offsets: prepaint. Paint API, listeners (`onMouseEvent`,
  `onKeyEvent`, `onAction`, `setKeyContext`, `setCursorStyle`, `insertTabStop`,
  `handleInput`): paint.
* Leaves with intrinsic size use `window.requestMeasuredLayout(style, ctx, measure)`.
* Containers lay out children via `child.requestLayout`, then `child.prepaint` /
  `child.paint` (`zpui.window.element.Children` is a ready-made child list).
* Elements and their states live in the frame arena; give a type `deinit(self)` if it owns
  gpa memory. **Listener captures must not point into the arena** (they are called after the
  frame is presented); capture ids, handles, hitboxes, element-state pointers.
* Element structs that forward the `Styled` methods (via `scripts/gen_styled.py --forward`)
  cannot use parameter names that collide with style methods (`p`, `w`, `h`, `m`, `size`, …).

## 10. Testing

`App.initTest` uses a headless platform: `app.openWindow` returns a `TestWindow`
(`zpui.core.test_platform.TestWindow.of(window.platform_window)`) and windows redraw as soon
as effects settle, so assertions can follow input directly:

```zig
const tw = TestWindow.of(w.platform_window);
tw.click(50, 30); tw.moveMouse(x, y); tw.typeKey("ctrl-s");
_ = tw.simulateInput(.{ .scroll_wheel = ... }); tw.simulateResize(size, 2.0); tw.simulateClose();
app.advanceClock(500 * std.time.ns_per_ms);           // tooltips, multi-stroke timeouts
w.rendered_frame.scene.quads.items                     // inspect what was painted
```

The fake text system lays every character out 10px wide at 16px. See
`src/window/tests.zig` for examples of every feature.

## 11. Differences from gpui

* No closures: listeners are `cx.listener(Self.method)` / `cx.listenerWith(data, …)` /
  free functions; scoped window state uses push/pop pairs.
* Handles are explicit: release `Entity`, `FocusHandle`, `ScrollHandle`, `Subscription`s
  in `deinit` (see core-model.md).
* `Div` is a handle; `id()` returns `StatefulDiv`. `.hover()` works without an id.
* Element phases cannot fail (OOM panics, like the core's fire-and-forget effects).
* Not ported yet: prompts, inspector, a11y,
  external file drags (they move the mouse but carry no payload), `anchor_scroll`,
  window-scoped `observe_in`/`spawn_in` (use the entity variants), presentation callbacks
  and the macOS native-view overlay plane.
