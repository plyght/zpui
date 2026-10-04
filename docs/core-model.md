# zpui core model (`src/app/`)

The reactive core is a port of gpui's `App` / `Entity` / `Context` / executor / keymap layer
(zui `crates/gpui/src/app.rs`, `app/entity_map.rs`, `app/context.rs`, `subscription.rs`,
`executor.rs`, `action.rs`, `keymap/`, `key_dispatch.rs`). Semantics match gpui unless noted.
Import it through `zpui.core` (main types are also re-exported at the `zpui` top level).

| file | contents |
|---|---|
| `app.zig` | `App`: entities, globals, effect queue + flush, observe/subscribe/release/new-entity APIs, keymap, action registry |
| `entity.zig` | `EntityId` (index + generation), `EntityMap` (slots, refcounts, lease flag, dropped list), `Entity(T)`, `WeakEntity(T)`, `AnyEntity`, `Lease(T)` |
| `context.zig` | `Context(T)`: entity-scoped API (notify, emit, observe, subscribe, spawn, timer, listener, ...) |
| `subscriber_set.zig` | `SubscriberSet`, `Subscription`, `Subscriptions` |
| `executor.zig` | `Executor`, `ForegroundExecutor`, `BackgroundExecutor`, `Task(R)`, `CancelToken`, job protocol |
| `action.zig` | action types, `AnyAction`, `ActionRegistry`, `NoAction`, `Unbind` |
| `key_context.zig` | `KeyContext`, `Predicate` (gpui `KeyBindingContextPredicate`) |
| `keymap.zig` | keystroke parse/format/match, `KeyBinding`, `BindingSpec`, `Keymap` |
| `dispatch_tree.zig` | `DispatchTree` (nodes, contexts, focus/view ids, listeners), `dispatchKey`/`flushDispatch`, `PendingInput` |
| `test_platform.zig` | `TestDispatcher` / `TestPlatform`: deterministic headless loop |
| `type_id.zig` | `TypeId` (comptime-known, `==`-comparable) |

## Ownership

* `App` is heap-allocated (`App.init(gpa, platform)` / `App.initTest(gpa)`); pointers to it are
  stable and everything runs on the main thread. `App.deinit` cancels tasks, destroys globals,
  destroys every remaining entity (calling `deinit`, **not** release listeners), then deinit's
  the platform.
* Entity values are heap-allocated by the App (stable addresses) and stored type-erased with a
  vtable (`type_id`, `type_name`, `destroy`). An entity type may declare
  `pub fn deinit(self: *T, cx: *App) void` (or `(self, Allocator)` or `(self)`) to release what
  it owns. Globals use the same convention.
* **Handles are explicit.** No RAII in Zig, so:
  * `Entity(T)` is a strong reference. Functions that *return* an `Entity` (`new`, `newWith`,
    `retain`, `WeakEntity.upgrade`, `cx.entity()`) hand you a reference that you must
    `release(cx)`. Handles *passed into* callbacks are borrowed.
  * `WeakEntity(T)` is a plain `{id}` value; liveness = matching generation and strong > 0.
  * `Subscription` must be `deinit()`ed (unsubscribe) or `detach()`ed. `Subscriptions` is a
    small list helper for views (`subs.add(gpa, sub)`, `subs.deinit(gpa)`).
  * `Task(R)` must be `cancel()`ed or `detach()`ed. Fields default to `.empty` / `.none` so a
    view can unconditionally cancel/deinit them in `deinit`.
  * A Subscription/Task must not outlive its App.
* Releasing the last strong handle only queues the id. The value is destroyed at the top of the
  next effect-flush iteration: its observers and event listeners are removed, tasks it owns are
  canceled, release listeners run with `*T`, then `T.deinit` runs and the memory is freed.
  Handles released by `deinit` are processed in the same flush loop (gpui
  `release_dropped_entities`).

## Leasing

gpui moves an entity's `Box` out of the map while updating it so `&mut T` and `&mut App` can
coexist. zpui keeps the value in place and sets `leased` on the slot:

* `entity.update(cx, method, args)` leases, builds a `Context(T)`, calls
  `method(value, args..., &cx)`, ends the lease, and (if outermost) flushes effects.
* `var l = entity.lease(cx); defer l.end(); l.value.x += 1; l.cx.notify();` is the closure-free
  form.
* Reading or updating an entity that is currently leased panics with gpui's message ("cannot
  update X while it is already being updated"). Other entities are freely readable/updatable.
  Globals lease the same way (`updateGlobal`); `globalMut` / `global` on a leased global panic.
* `cx: anytype` everywhere accepts `*App` or any `*Context(T)` (anything with an `app` field).

## Effects and ordering

`App.startUpdate/finishUpdate` count nesting; when the outermost update finishes, `flushEffects`
loops: release dropped entities → pop one effect → apply, until the queue is empty, then the
event arena is reset. Effects queued while flushing are processed in the same flush, FIFO.

* `notify` (deduplicated per entity until delivered), `emit` (event copied into the event arena,
  matched by `TypeId`), `notify_global_observers` (deduplicated), `deferred`,
  `entity_created` (holds a strong ref until delivered), `refresh_windows` (no-op until the
  window phase).
* Observers / event listeners / global observers are inserted **inactive** and activated by an
  `activate` effect queued at subscription time (gpui `defer(activate)`). So a listener added
  during an emit does not see that emit, and an observer registered after a `notify` in the same
  update misses it. Release listeners and `observeNew` listeners are active immediately.
* `SubscriberSet.retain` tolerates reentrancy: subscribers added during a walk are not visited,
  ones dropped during the walk are skipped and freed afterwards, a callback returning `false`
  unsubscribes, re-entrant retain on the same key is a no-op.
* Every public mutating App method wraps itself in an update, so top-level calls also flush.
* OOM: registering APIs return errors; fire-and-forget effects (`notify`, `emit`, `defer`)
  panic on OOM, keeping view code free of `try` in hot paths.

## Callbacks

gpui closures become `{func, captures}` pairs (`app.Captures`: two `u64` + optional pointer with
free fn). Comptime wrappers generate `func` from typed functions, so typical registrations do not
allocate. Two flavours:

* **Entity-bound** (`Context(T)` methods take a method reference; captures are the entity ids):
  ```zig
  fn init(buffer: Entity(Buffer), cx: *Context(Editor)) !Editor {
      var self: Editor = .{ .buffer = buffer.retain(cx) };
      try self.subs.add(cx.gpa(), try cx.observe(buffer, Editor.onBufferChanged));
      try self.subs.add(cx.gpa(), try cx.subscribe(buffer, Editor.onEdited));
      return self;
  }
  fn onBufferChanged(self: *Editor, buffer: Entity(Buffer), cx: *Context(Editor)) void { ... }
  fn onEdited(self: *Editor, buffer: Entity(Buffer), ev: *const Buffer.Edited, cx: *Context(Editor)) void { ... }
  ```
  The callback upgrades both ends; if either is gone it returns false and is pruned. Signatures:
  `observe f(*T, Entity(W), *Context(T))`, `subscribe f(*T, Entity(E), *const Ev, *Context(T))`
  (event type inferred from `f`), `observeRelease f(*T, *W, *Context(T))`,
  `observeGlobal(G, f(*T, *Context(T)))`, `onRelease f(*T, *App)`, `deferUpdate f(*T, *Context(T))`,
  `listener(f(*T, *const Event, *Context(T)))` → `Listener(Event)` for elements.
* **Context-pointer** (App methods): `app.observe(entity, ctx_ptr_or_void, f)` with
  `f(ctx, Entity(W), *App)`, likewise `subscribe`, `observeRelease`, `observeGlobal`,
  `observeNew`, `deferFn`. The pointer is not owned.

Events: an entity declares what it emits with `pub const Events = .{ A, B };` (or
`pub const Event = A;`); `cx.emit` / `subscribe` check this at compile time (gpui
`EventEmitter<E>`).

Entity construction: `app.new(T, value)` or `app.newWith(T, T.init, .{args})` where
`init(args..., cx: *Context(T))` returns `T` or `!T` — the context exists before the value so
constructors can subscribe (gpui `cx.new(|cx| ...)`). Constructor errors release the slot.

## Async

Zig 0.17 has no stackless coroutines, and `std.Io.async/concurrent` futures can only be
*awaited* (blocking) or canceled — there is no completion callback that could resume work on the
UI thread. So zpui uses **jobs** (plain struct values) scheduled through the platform
`Dispatcher`:

```zig
const Load = struct {
    path: []const u8,
    pub fn run(self: *Load) LoadResult { ... }       // optional: worker thread; may use std.Io
    // also optional: run(self, token: CancelToken), discard(self, R), deinit(self)
};
self.task = try cx.spawn(Load{ .path = p }, Editor.onLoaded);   // fn(*Editor, LoadResult, *Context(Editor))
self.blink = try cx.timer(500 * std.time.ns_per_ms, Editor.onBlink); // fn(*Editor, *Context(Editor))
```

* `run` executes on a background worker (must not touch the App); then `finish` runs on the main
  thread. `Context.spawn` wraps the job so `finish` re-enters as `onLoaded(self, result, cx)`
  through a weak handle — the Zig spelling of `cx.spawn(async move |this, cx| ...)`.
* Multi-step flows are chains: the main-thread callback spawns the next job.
* `Task(R)`: `cancel()` (finish never runs; a produced result goes to `discard`), `detach()`,
  `isReady()`, `result()`. States: pending → running → ran → completed | canceled (atomic).
* Tasks spawned through `Context` are owned by the entity and canceled when it is released.
* Lower level: `app.foregroundExecutor().spawn/timer(job)`, `app.backgroundExecutor().spawn(job)`
  / `.timer(ns)`; the job's own `finish(self[, R])` runs on the main thread.
* Task memory may be freed on a worker thread: the App allocator must be thread-safe.

`TestPlatform` / `TestDispatcher` run everything on the calling thread: nothing executes until a
test calls `app.runUntilParked()` (foreground first, then background, FIFO) or
`app.advanceClock(ns)` (fires due timers in deadline order, parking after each).

## Actions and keymap

* Action = struct with `pub const action_name = "ns::Name"`; `action("ns::Name")` makes a unit
  action. Fields are data (borrowed slices). `AnyAction` is the owned erased form (`is`,
  `downcast`, `eql`, `clone`). `ActionRegistry` maps names → default builders (for data-driven
  keymaps); `NoAction` and `Unbind{ .target }` are built in.
* `parseKeystroke`: `[secondary-][ctrl-][alt-][shift-][cmd|super|win-][fn-]key[->key_char]`,
  uppercase single letters imply shift, `ctrl--` is ctrl+minus, a lone modifier is the key.
  `shouldMatch` also accepts the typed `key_char` (e.g. alt-s → "ß").
* `KeyContext` (`"Editor mode=full"`, `initWithDefaults` adds `os=…`) and `Predicate`
  (`a && !b`, `x == y`, `x != y`, `Parent > Child`, parens; `!x` means x matches nowhere in the
  stack) port gpui exactly, including `depthOf` and `isSuperset`.
* `Keymap.bindingsForInput(gpa, typed, contexts)` → `{bindings, pending}` with gpui precedence:
  deeper context match wins, then later-added; context-less bindings match at the deepest level;
  `NoAction` (user meta 0 / unset) stops the search; `Unbind` removes a named action; an exact
  match added *after* a multi-stroke prefix overrides it (no pending).
* `app.bindKeys(&.{ .init("cmd-k cmd-s", SaveAll{}, "Editor && !Terminal") })`.

## DispatchTree (keybinding part)

Built per frame by the window (phase 3): `pushNode`, `setKeyContext`, `setFocusId`, `setViewId`,
`onAction` / `onKeyEvent` / `onModifiersChanged`, `popNode`; `setActiveNode` re-enters a node
in paint; `reuseSubtree` moves a cached view's nodes (and listeners) from the previous frame;
`truncate` rolls back. Queries: `dispatchPath`, `focusPath`, `focusContains`,
`viewPathReversed`, `isActionAvailable`, `availableActionTypes`, `bindingsForAction` /
`highestPrecedenceBindingForAction` (shadowing-aware).

Key handling: `dispatchKey(gpa, pending, keystroke, path)` returns bindings to dispatch now,
new pending input (+ `pending_has_binding`), keystrokes to replay first, and the context stack.
The window keeps a `PendingInput` (owns keystroke copies, focus, timer); when the pending prefix
is itself bound (or text input would consume it) it arms a `PendingInput.timeout_ns` (1 s)
foreground timer whose job calls `flushDispatch` and replays. See the
"PendingInput times out after 1s" test for the reference flow; the real flow lives in
`src/window/dispatch.zig`.

## Window integration

Implemented in `src/window/` (see [elements.md](elements.md)); the core pieces it relies on:

* `App.windows` registry (`openWindow(options, V, init, args)` → `WindowHandle(V)`,
  `windowById`, `updateWindow`), closed windows are destroyed when effects settle; under
  `initTest`, dirty windows are drawn (and presented to a `TestWindow`) at the same point.
* `notify` → window invalidation: each draw records the entities read/updated
  (`EntityMap.track_accessed`), and notifying one of them marks the window (and the view's
  ancestors) dirty and requests a frame. `refresh_windows` redraws everything.
* `FocusMap` / `FocusHandle` (`app.focusHandle()`, `cx.focusHandle()`), window focus
  listeners (`cx.onFocus/onBlur/onFocusIn/onFocusOut`, stored in `App.focus_listeners`).
* `cx.listener(f)` accepts `fn(*T, *const E, *Window, *Context(T))` or the window-less form;
  `cx.listenerWith(data, f)` captures up to 24 bytes. `Listener(E)` is a plain value
  (function pointer + inline `ListenerData`), also constructible from free functions.
* DispatchTree listeners carry inline `Captures` (`window/callback.zig`) and receive the
  `*Window` (as `?*anyopaque`); the window builds the tree during prepaint/paint and runs
  key/action dispatch (`window/dispatch.zig`), including the `PendingInput` timeout flow.
* `App.propagate_event` (`cx.stopPropagation()` / `cx.propagate()`), global action listeners
  (`app.onAction`), `App.active_drag` (`hasActiveDrag`, `activeDrag(T)`, `cancelDrag`),
  the shared `TextSystem` (`app.textSystem()`, `app.addFont`) and `image_services`.

Not yet: window-scoped `observe_in` / `subscribe_in` / `spawn_in` variants (use the entity
forms and look the window up with `app.windowById`).

## App lifecycle and menus (`src/app/lifecycle.zig`)

`App.init` registers the platform's `PlatformCallbacks` and re-exposes them as listeners:
`onQuit` (runs once, as the run loop exits), `onShouldQuit` (veto: `requestQuit()` — menu
Quit, ⌘Q, macOS Dock/logout termination — asks every listener; `quit()` is never vetoed),
`onReopen` (Dock click with no visible window), `onOpenUrls` (URL schemes; URLs arriving
before the first listener are queued — `zpui.lifecycle.openUrls` feeds argv the same way),
`onSystemWake`, `onKeyboardLayoutChange`, `onNotificationActivated(tag)`. Windows add
`onShouldClose` (veto the frame's close button) and `observeBounds` (moved / resized), and
report `displayId()`; `WindowOptions.display_id` opens on a given display (`Display.uuid`,
`.primary` identify displays across launches).

`app.setMenus(&.{ zpui.Menu{ .name = "Edit", .items = &.{ .action("Undo", Undo{}), .separator,
.osAction("Copy", Copy{}, .copy) } } })` installs the menu bar (macOS): items dispatch their
action to the active window's focus path (else to global `onAction` listeners), validate with
the same availability rule (`app.isActionAvailable`), and show key equivalents rendered from
the keymap at call time (call again after re-binding). Also: `hide` / `hideOtherApps` /
`unhideOtherApps`, `activate`, `postNotification`, `playSound`, `displays`, `activeWindow`,
`dispatchAction`. The TestPlatform records menus / notifications / sounds and simulates the
OS side (`simulateReopen`, `simulateOpenUrls`, `simulateTerminate`, `simulateMenuAction`,
`simulateNotificationClick`, `TestWindow.simulateCloseButton` / `simulateMove` /
`simulateActive`).
