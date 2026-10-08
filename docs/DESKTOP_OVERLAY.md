# Desktop overlay, global input, tray, foreground app

Contract for the platform features a desktop companion app (typebud) needs. Every backend
(`mac`, `linux` X11 + Wayland, `windows`) implements the same surface in `src/platform/platform.zig`;
unsupported pieces return `error.Unsupported` / `.unsupported` instead of being absent.

## 1. Overlay windows

`WindowKind.overlay` (new). A borderless, undecorated window that:

- is always on top of normal windows, on every Space / virtual desktop / workspace, and over
  fullscreen apps where the OS allows it (mac: `NSPanel` non-activating, level `.statusBar`,
  `canJoinAllSpaces | fullScreenAuxiliary | stationary | ignoresCycle`; X11: override-redirect
  off, `_NET_WM_STATE_ABOVE|STICKY|SKIP_TASKBAR|SKIP_PAGER`, `_NET_WM_WINDOW_TYPE_UTILITY` or
  `DOCK`; Wayland: `zwlr_layer_shell_v1` overlay layer when available, else xdg-toplevel best
  effort; Windows: `WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_LAYERED`),
- never takes keyboard focus or activates the app when shown or clicked,
- has no taskbar / dock / alt-tab entry,
- pairs with `background = .transparent` for per-pixel alpha (premultiplied).

`WindowParams` additions:

```zig
/// Mouse events pass through to whatever is below. Toggle later with `Window.setMousePassthrough`.
mouse_passthrough: bool = false,
/// Overlay placement. When set, `bounds.origin` is ignored and the window is pinned to a corner
/// of the display's visible (work-area) bounds, offset inward by `margin`.
/// Wayland layer-shell maps this to anchors + margins (clients can't position themselves otherwise).
anchor: ?OverlayAnchor = null,
```

```zig
pub const OverlayCorner = enum { top_left, top_right, bottom_left, bottom_right };
pub const OverlayAnchor = struct { corner: OverlayCorner = .bottom_right, margin: Point = .{ .x = 16, .y = 16 } };
```

`Window.VTable` additions:

```zig
setMousePassthrough: *const fn (ptr: *anyopaque, on: bool) void,
setAnchor: *const fn (ptr: *anyopaque, anchor: OverlayAnchor, display_id: ?u32) void,
setVisible: *const fn (ptr: *anyopaque, visible: bool) void,   // hide/show without destroying
```

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

`Platform.VTable` additions:

```zig
/// Callback runs on the main thread. Returns the status of the strongest backend it could start.
startGlobalInputMonitor: *const fn (ptr: *anyopaque, cb: Callback(GlobalInputEvent, void)) InputMonitorStatus,
stopGlobalInputMonitor: *const fn (ptr: *anyopaque) void,
inputPermission: *const fn (ptr: *anyopaque) InputPermission,
/// Shows the OS prompt / opens the right settings pane. No-op where not applicable.
requestInputPermission: *const fn (ptr: *anyopaque) void,
```

Backends:

| OS | Primary | Fallback |
|---|---|---|
| macOS | `CGEventTapCreate` (listen-only, `kCGEventTapOptionListenOnly`) on the main run loop; permission via `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` (Input Monitoring) | `NSEvent addGlobalMonitorForEventsMatchingMask` (needs Accessibility) |
| Linux X11 (and XWayland apps) | XInput2 `XI_RawKeyPress/Release`, `XI_RawButtonPress` on the root window, own `Display` connection integrated into the epoll loop | — |
| Linux Wayland (any compositor) | evdev: enumerate `/dev/input/event*` with `EV_KEY` keyboard capability, read non-blocking in the epoll loop, hotplug via inotify on `/dev/input`; status `needs_permission` when no device is readable (user not in `input` group) | XInput2 against XWayland if `DISPLAY` is set (sees XWayland clients only) |
| Windows | `SetWindowsHookExW(WH_KEYBOARD_LL / WH_MOUSE_LL)` on the UI thread | Raw Input `RIDEV_INPUTSINK` |

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
setTrayItem: *const fn (ptr: *anyopaque, item: ?TrayItem) anyerror!void,
```

macOS `NSStatusItem`; Linux StatusNotifierItem + `com.canonical.dbusmenu` over the existing pure-Zig
D-Bus client (status `error.Unsupported` when no watcher is registered); Windows `Shell_NotifyIconW`
+ `TrackPopupMenu`.

## 4. Foreground application

```zig
pub const ForegroundApp = struct {
    /// Stable identifier: bundle id (mac), executable basename (Windows), WM_CLASS / app_id (Linux).
    id: []const u8,
    name: []const u8,
};
/// Copies into `buf`; null when unknown (e.g. Wayland without a foreign-toplevel protocol).
foregroundApp: *const fn (ptr: *anyopaque, buf: []u8) ?ForegroundApp,
/// Fires on the main thread whenever the foreground app changes.
setForegroundAppCallback: *const fn (ptr: *anyopaque, cb: Callback(void, void)) void,
```

macOS `NSWorkspace.frontmostApplication` + `didActivateApplicationNotification`; X11
`_NET_ACTIVE_WINDOW` property-change events + `WM_CLASS`; Wayland `zwlr_foreign_toplevel_manager_v1`
(wlroots, KDE) or `ext_foreign_toplevel_list_v1`, else null; Windows `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`
+ `QueryFullProcessImageNameW`.

## 5. Launch at login

```zig
setLaunchAtLogin: *const fn (ptr: *anyopaque, app_id: []const u8, exe_path: []const u8, on: bool) anyerror!void,
```

macOS `SMAppService.mainApp`, Linux `~/.config/autostart/<app_id>.desktop`, Windows
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
