# Desktop overlay, global input, tray, foreground app

Contract for the platform features a desktop companion app (typebud: a typing pet in a small
transparent always-on-top window that animates when you type anywhere) needs. Every backend
(`mac`, `linux` X11 + Wayland, `windows`) implements the same surface in `src/platform/platform.zig`.

**All new vtable entries are optional** (`?*const fn ... = null`), so existing backends and callers
are unaffected; the `Window` / `Platform` wrapper methods treat null as unsupported (no-op, `null`,
`.unsupported`, `.not_applicable` or `error.Unsupported`). A backend that implements a piece sets
its entry. Existing window kinds keep their behavior.

Status: macOS (`src/platform/mac/{window,desktop,mac}.zig`), Linux X11 + Wayland
(`src/platform/linux/{x11,wayland,global_input,tray,linux}.zig`) and `TestPlatform`
(`src/app/test_platform.zig`) implement everything below. Pure, unit-tested helpers shared by all
backends live in `src/platform/desktop.zig` (`platform.desktop`).

## 1. Overlay windows

`WindowKind.overlay`. A borderless, undecorated window that:

- is always on top of normal windows, on every Space / virtual desktop / workspace, and over
  fullscreen apps where the OS allows it,
- never takes keyboard focus or activates the app when shown or clicked (`Window.activate` is a
  no-op for overlays),
- has no taskbar / dock / alt-tab entry,
- pairs with `background = .transparent` for per-pixel alpha (premultiplied).

| Backend | How |
|---|---|
| macOS | `NSPanel` with only `NSWindowStyleMaskNonactivatingPanel` (borderless), `canBecomeKey/MainWindow` = NO, level `NSStatusWindowLevel`, collection behavior `canJoinAllSpaces \| fullScreenAuxiliary \| stationary \| ignoresCycle`, floating panel, `hidesOnDeactivate = NO`, no shadow, shown with `orderFrontRegardless`. Transparent: `CAMetalLayer.opaque = NO`, window `opaque = NO`, clear color alpha 0 |
| X11 | 32-bit ARGB visual + colormap when transparent (needs a compositor for real alpha; without one the transparent pixels are black), `_NET_WM_WINDOW_TYPE_UTILITY`, `_NET_WM_STATE_ABOVE\|STICKY\|SKIP_TASKBAR\|SKIP_PAGER`, `_NET_WM_DESKTOP = 0xFFFFFFFF`, `WM_HINTS.input = False`, Motif no-decorations, `WM_NORMAL_HINTS` min = max = size + program position |
| Wayland | `zwlr_layer_shell_v1` **overlay** layer (wlroots compositors: sway, Hyprland, river, labwc, Wayfire; KDE Plasma; COSMIC): anchors + margins, `keyboard_interactivity = none`, exclusive zone 0. Set `ZPUI_NO_LAYER_SHELL=1` to force the fallback. **Fallback without layer-shell (GNOME / Mutter, weston): a plain fixed-size `xdg_toplevel`** (min = max size, client-side "decorations" = none drawn). The compositor places it, it stacks like a normal window, it may take focus when clicked and it is not on every workspace — there is no Wayland protocol on GNOME to do better. `screenMousePosition` returns null there and `setAnchor` only records the anchor |
| Windows | `WS_EX_TOPMOST\|WS_EX_TOOLWINDOW\|WS_EX_NOACTIVATE\|WS_EX_LAYERED` |

Vulkan swapchains of transparent windows use `VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR` (else
inherit / opaque, whatever the surface supports).

`WindowParams` additions:

```zig
/// Mouse events pass through to whatever is below. Toggle later with `Window.setMousePassthrough`.
mouse_passthrough: bool = false,
/// Overlay placement. When set, `bounds.origin` is ignored and the window is pinned to a corner
/// of the display's visible (work-area) bounds, offset inward by `margin`.
/// Wayland layer-shell maps this to anchors + margins (clients can't position themselves otherwise).
anchor: ?OverlayAnchor = null,
```

`display_id` picks the display (Wayland layer-shell: the `wl_output`, fixed at creation).

```zig
pub const OverlayCorner = enum { top_left, top_right, bottom_left, bottom_right };
pub const OverlayAnchor = struct { corner: OverlayCorner = .bottom_right, margin: Point = .{ .x = 16, .y = 16 } };
```

Work area: macOS `NSScreen.visibleFrame` (menu bar + Dock excluded); X11 `_NET_WORKAREA` of
`_NET_CURRENT_DESKTOP` (whole screen when the WM publishes none); Wayland layer-shell margins are
measured by the compositor from other surfaces' exclusive zones (panels), i.e. from the work area.

`Window.VTable` additions (all optional):

```zig
setMousePassthrough: ?*const fn (ptr: *anyopaque, on: bool) void = null,
setAnchor: ?*const fn (ptr: *anyopaque, anchor: OverlayAnchor, display_id: ?u32) void = null,
setVisible: ?*const fn (ptr: *anyopaque, visible: bool) void = null,   // hide/show without destroying
setInputRegion: ?*const fn (ptr: *anyopaque, rects: ?[]const Bounds) void = null,
screenMousePosition: ?*const fn (ptr: *anyopaque) ?Point = null,
```

Wrappers: `platform.Window.setMousePassthrough / setAnchor / setVisible / setInputRegion /
screenMousePosition`, and the same names on the core `zpui.Window` (`src/window/window.zig`).

### Visibility

`setVisible(false)` hides without destroying and makes a hidden overlay cost ~nothing:

- macOS: `orderOut:`, display link stopped, frame requests dropped, renderer scratch trimmed;
  the permissionless input poller is suspended while every overlay is hidden.
- X11: unmapped, frame timer cancelled, Vulkan swapchain released (`Renderer.parkSwapchain`).
- Wayland: null buffer committed (unmapped), frame callback dropped, swapchain released; showing
  re-commits and draws on the compositor's configure.

`requestFrame` on a hidden window is ignored; `zpui.Window.setVisible(true)` redraws.

### Input regions and passthrough

`setInputRegion(rects)` — rects in window content coordinates (logical px, y down):

- `null`: the whole window takes mouse input (default),
- empty slice: fully click-through,
- otherwise only the rects take input; everything else goes to the windows below.

`setMousePassthrough(true)` overrides the region (all click-through) until switched off. The rects
are copied.

- macOS: AppKit has no per-region click-through, so the panel's `ignoresMouseEvents` is flipped from
  the pointer position: re-evaluated on the overlay's own mouse moves and, while a region is set,
  on a global mouse-moved/dragged `NSEvent` monitor (no permission needed). While a button is down
  inside the window it keeps taking input (drags).
- X11: XShape input shape (`ShapeInput`; empty = passthrough, reset = whole window).
- Wayland: `wl_surface.set_input_region` with a `wl_region` (applied with the next commit).

### Resize, drags, screen position

`Window.resize(size)` (vtable `resize`) on an **anchored** overlay keeps the anchored corner fixed:

- macOS: coalesced to one `setFrame:display:` per main-queue turn with the origin recomputed from
  the anchor; the view's `setFrameSize:` resizes the `CAMetalLayer` drawable synchronously and the
  new frame is drawn with `presentsWithTransaction` inside the same Core Animation transaction (no
  stretched or jumping frame). No allocation per resize.
- X11: min = max size hints, then one `ConfigureWindow` with x, y, width and height.
- Wayland layer-shell: `set_size` (+ anchors / margins) and the new-size buffer go out in the same
  `wl_surface.commit` (the frame drawn by the resize). xdg fallback: min = max size + new buffer.
- Vulkan swapchain recreation reuses the old swapchain (`oldSwapchain`) and frees it; nothing leaks.
  The overlay demo does 60 resizes in ~0.5 s on Xvfb + lavapipe (≈120/s) and ~0.7 s on weston.

Unanchored overlays keep their top-left corner.

App-drawn resize handles / drag-to-move (what typebud does):

1. On `mouse_down` inside the window, record `w.screenMousePosition()`, the current size and margin.
   The press holds an implicit pointer grab on every backend (X11 core grab, Wayland implicit grab,
   AppKit drag tracking), so `mouse_move` / `mouse_up` keep arriving outside the window until the
   button is released.
2. On `mouse_move`, `delta = screenMousePosition() - start`:
   - resize: `platform.desktop.aspectResize(anchor.corner, start_size, delta, min_w, max_w)` (aspect
     locked; growth away from the anchor corner) → `Window.resize`, then update `setInputRegion`;
   - move: new `anchor.margin` from the start margin and delta (sign depends on the corner) →
     `setAnchor(anchor, display_id)`.

`screenMousePosition()`: the pointer in global logical coordinates, y down; use deltas between
readings. macOS: `NSEvent.mouseLocation` flipped against the primary screen (origin at its top-left).
X11: root coordinates of the last pointer event. Wayland layer-shell: the output's position + the
anchored origin computed from anchor, margins and the output's logical size (panel exclusive zones
are unknown to clients) + the surface-local pointer. Wayland xdg fallback: null.

Moving to another monitor: `setAnchor(anchor, display_id)` with the target display (macOS: any
`Display.id`; X11: one screen; Wayland layer-shell: the output is fixed at creation — reopen the
window with `WindowParams.display_id`). macOS updates scale / display link on `windowDidChangeScreen`.

## 2. Global input monitor

Observes (never consumes, never records text) keyboard and mouse activity system-wide.

```zig
pub const GlobalInputKind = enum { key_down, key_up, mouse_down, mouse_up, scroll };
/// Coarse key class only: the app animates, it never needs which character was typed.
pub const GlobalKeyClass = enum { letter, digit, space, enter, backspace, tab, modifier, arrow, other };
pub const GlobalInputEvent = struct {
    kind: GlobalInputKind,
    key: GlobalKeyClass = .other,
    /// Rough horizontal position of the key on a US layout, 0 = far left, 1 = far right.
    /// Lets the companion move its left/right paw. 0.5 when unknown.
    key_x: f32 = 0.5,
    timestamp_ns: u64,
};
pub const InputMonitorStatus = enum { ok, needs_permission, unsupported };
pub const InputPermission = enum { granted, denied, not_determined, not_applicable };
```

`Platform.VTable` additions (all optional):

```zig
/// Callback runs on the main thread. Returns the status of the strongest backend it could start.
startGlobalInputMonitor: ?*const fn (ptr: *anyopaque, cb: Callback(GlobalInputEvent, void)) InputMonitorStatus = null,
stopGlobalInputMonitor: ?*const fn (ptr: *anyopaque) void = null,
/// Opt into (true) or out of (false, the default) the precise backend where the default one
/// needs no permission (macOS). Takes effect immediately on a running monitor (restart) or on
/// the next start. No-op where every backend is already precise (Linux, Windows).
setPreciseInput: ?*const fn (ptr: *anyopaque, on: bool) void = null,
inputPermission: ?*const fn (ptr: *anyopaque) InputPermission = null,
/// Shows the OS prompt / opens the right settings pane. No-op where not applicable
/// (including macOS permissionless mode).
requestInputPermission: ?*const fn (ptr: *anyopaque) void = null,
```

`setPreciseInput` is the contract's "global input options": the only option is `precise`. Keycodes
map through `platform.desktop.evdevKey` (Linux / X11 keycode − 8) and `platform.desktop.macKey`
(`kVK_*`); characters are never derived, stored or exposed.

Backends:

| OS | Default | Precise / fallback |
|---|---|---|
| macOS | **No permission, no TCC prompt.** `CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, kCGEventKeyDown)` polled from a GCD timer on the main queue; each increase becomes that many `key_down` events (`platform.desktop.CounterDecoder`, ≤ 32 per poll): `key = .other`, `key_x` alternating left / right with a little deterministic jitter, the matching `key_up` on the next poll. Gated by `CGEventSourceSecondsSinceLastEventType(…, keyDown)` (one cheap call when idle). Adaptive rate (`counterPollInterval`): 60 Hz for 2 s after a key, 20 Hz up to 6 s, then 4 Hz, leeway half the interval; suspended while every overlay window is hidden. `CGEventSourceKeyState` is sampled for letters / digits / space / enter / backspace / tab / arrows when keys are counted; `platform.desktop.KeySampler` probes whether it returns real states without permission (works once any key reads pressed, abandoned after 12 counting polls without one) — then keys keep their real class and position. Clicks and scrolls: `NSEvent addGlobalMonitorForEventsMatchingMask:` for mouse down / up and scroll (no permission). `inputPermission()` = `.not_applicable` | `setPreciseInput(true)`: listen-only `CGEventTapCreate` (`kCGSessionEventTap`, `kCGEventTapOptionListenOnly`) on the main run loop; needs Input Monitoring. `startGlobalInputMonitor` returns `.needs_permission` (checked with `CGPreflightListenEventAccess`, never prompting); `requestInputPermission` calls `CGRequestListenEventAccess` (or opens System Settings → Privacy → Input Monitoring when denied); `inputPermission` from `IOHIDCheckAccess`. The tap callback only classifies into a fixed ring and schedules one drain |
| Linux X11 (and XWayland) | XInput2 `XI_RawKeyPress/Release`, `XI_RawButtonPress/Release` on the root window over a dedicated `Display` whose fd sits in the epoll loop; autorepeat skipped. `inputPermission` = `.not_applicable` | evdev when XInput2 is unavailable |
| Linux Wayland (any compositor) | evdev: every readable `/dev/input/event*` with a keyboard (`KEY_A`) or pointer (`BTN_LEFT`) capability, non-blocking, read in batches of 64 `input_event`s into a stack buffer from the epoll loop; inotify on `/dev/input` for hotplug and permission changes. `.needs_permission` when devices exist but none is readable (user not in the `input` group; `requestInputPermission` logs the `usermod -aG input` hint), `inputPermission` = `.granted` / `.denied` | XInput2 against XWayland if `DISPLAY` is set (sees XWayland clients only) |
| Windows | `SetWindowsHookExW(WH_KEYBOARD_LL / WH_MOUSE_LL)` on the UI thread | Raw Input `RIDEV_INPUTSINK` |

All backends push into a fixed 64-entry `platform.desktop.InputQueue` (oldest dropped when full) and
drain it once per wakeup: bursts coalesce, nothing allocates, the callbacks run on the main thread.

## 3. Tray / menu bar item

```zig
pub const TrayItem = struct {
    /// PNG bytes (RGBA). macOS marks it as a template image when `template` is set.
    icon_png: []const u8,
    template: bool = true,
    tooltip: []const u8 = "",
    /// Reuses the existing app menu item model (`menu_action` callback receives the tag).
    menu: []const MenuItem,
};
setTrayItem: ?*const fn (ptr: *anyopaque, item: ?TrayItem) anyerror!void = null,
```

macOS `NSStatusItem` (variable length, icon scaled to 18 pt) with an `NSMenu` from the menu model,
items targeting the app delegate; Linux StatusNotifierItem + `com.canonical.dbusmenu` over the
pure-Zig D-Bus client (`error.Unsupported` when no `org.kde.StatusNotifierWatcher` is registered,
e.g. GNOME without the AppIndicator extension); Windows `Shell_NotifyIconW` + `TrackPopupMenu`.

## 4. Foreground application

```zig
pub const ForegroundApp = struct {
    /// Stable identifier: bundle id (mac), executable basename (Windows), WM_CLASS / app_id (Linux).
    id: []const u8,
    name: []const u8,
};
/// Copies into `buf`; null when unknown (e.g. Wayland without a foreign-toplevel protocol).
foregroundApp: ?*const fn (ptr: *anyopaque, buf: []u8) ?ForegroundApp = null,
/// Fires on the main thread whenever the foreground app changes.
setForegroundAppCallback: ?*const fn (ptr: *anyopaque, cb: Callback(void, void)) void = null,
```

macOS `NSWorkspace.frontmostApplication` + `NSWorkspaceDidActivateApplicationNotification`; X11
`_NET_ACTIVE_WINDOW` property-change events on the root + `WM_CLASS` (class part); Wayland
`zwlr_foreign_toplevel_manager_v1` (wlroots compositors) — the activated toplevel's `app_id`
(titles are ignored). `ext_foreign_toplevel_list_v1` is not used: it has no activated state, so it
cannot tell which app is in front. GNOME and KDE Plasma expose neither to ordinary clients: null.
Windows `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` + `QueryFullProcessImageNameW`.

## 5. Launch at login

```zig
setLaunchAtLogin: ?*const fn (ptr: *anyopaque, app_id: []const u8, exe_path: []const u8, on: bool) anyerror!void = null,
```

macOS `SMAppService.mainAppService` (macOS 13+, bundled apps), else a per-user LaunchAgent
`~/Library/LaunchAgents/<app_id>.plist` (`platform.desktop.writeLaunchAgentPlist`); Linux
`$XDG_CONFIG_HOME/autostart/<app_id>.desktop` (default `~/.config/autostart`,
`platform.desktop.writeAutostartEntry`, `Exec` quoted per the Desktop Entry spec); Windows
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

## 6. App-level API (`src/app/desktop.zig`)

```zig
const status = app.startGlobalInputMonitor(&pet, Pet.onInput);   // fn(*Pet, GlobalInputEvent, *App)
app.setPreciseInput(false);                                      // macOS: permissionless (default)
try app.onForegroundAppChange(&pet, Pet.foregroundChanged);      // fn(*Pet, *App)
var buf: [256]u8 = undefined;
if (app.foregroundApp(&buf)) |fg| hideWhen(fg.id);
try app.setTray(.{ .icon_png = icon, .tooltip = "typebud", .items = &.{ .action("Quit typebud", Quit{}) } });
try app.setLaunchAtLogin("typebud", exe_path, true);
```

Callbacks run inside an update on the main thread. Tray actions dispatch like menu bar picks and use
tags from `tray_tag_base` (1 << 30) up, so they never collide with `setMenus`. `Context(T).platform()`
gives the raw `Platform` for the rest.

macOS menu bar apps without a Dock icon: set `LSUIElement` in the bundle's Info.plist (honored by
the platform's activation policy), or `ZPUI_ACCESSORY_APP=1` for unbundled runs.

## 7. Performance

- Frames are drawn only on `requestFrame`; macOS parks the display link after 30 idle ticks, X11
  ticks a one-shot timer per request, Wayland uses frame callbacks only while frames are requested.
  The epoll loop blocks (`epoll_wait(-1)`) when nothing is pending.
- Hidden overlays: no display link / timers / frame callbacks, swapchain released (above).
- Input paths classify into the fixed ring (no allocation, no AppKit in the tap callback); evdev
  reads batch into a fixed buffer; one callback round per wakeup.
- Wayland: a prepared display read never outlives `epoll_wait` (`EventLoop.Hooks.after_wait`), so a
  frame presented from a timer or input handler never blocks in Mesa's `wl_display_read_events`.

Measured with `ZPUI_SMOKE_FRAMES=30 zig build overlay-demo` (global input monitor running, pet idle):
**0 frames and 0 ms CPU over 2 s** on Xvfb + lavapipe (X11) and on weston headless (Wayland,
xdg fallback). macOS idle cost is the 4 Hz key-counter poll (one `CGEventSourceSecondsSinceLastEventType`
call per tick) and nothing while every overlay is hidden.

## 8. Demo and checks

`zig build overlay-demo` (examples/overlay_demo.zig): transparent overlay bottom-right, a rounded
blob pulsing on each global key / click, a resize handle (top-left, aspect-locked, anchor corner
fixed), drag the blob to move it, input region = blob + handle, tray with Hide / Show and Quit.
`ZPUI_SMOKE_FRAMES=N` renders N frames, does 60 anchored resizes and a hide / show, measures 2 s of
idle (exit 1 if any frame is drawn), writes `zig-out/overlay-demo.png` (the scene through an
offscreen renderer with alpha) and exits; `ZPUI_SMOKE_INPUT_WAIT_MS=ms` waits for injected input
first and prints how many global events arrived. `zig build overlay-demo-build` only installs
`zig-out/bin/overlay-demo` (for scripted runs that inject input, e.g. `xdotool` under Xvfb). `zig build mac-check -Dtarget=aarch64-macos` also
compiles the demo against the macOS backend.

Unit tests: `src/platform/desktop.zig` (anchor geometry incl. y-up and resize, aspect resize,
keycode tables, input ring, poll intervals, counter decoder, key sampler probe, autostart / plist
contents), `src/platform/linux/global_input.zig` (evdev + XI2 decoding), `src/platform/linux/tray.zig`
(SNI + dbusmenu), `src/app/desktop_tests.zig` (App API on `TestPlatform`).
