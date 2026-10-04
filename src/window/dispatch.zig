//! Input dispatch for a Window (gpui `dispatch_event`, `dispatch_mouse_event`,
//! `dispatch_key_event`, `dispatch_action_on_node`).
//!
//! * Mouse events go to the rendered frame's mouse listeners: capture phase in registration
//!   order (back to front, parents first), then bubble phase in reverse (topmost first).
//!   `cx.stopPropagation()` ends dispatch.
//! * Key events go through the keymap first (multi-stroke pending input with a 1 s timeout,
//!   replay of abandoned prefixes), then to raw key listeners along the focus path
//!   (capture root → focus, bubble focus → root), then modifiers-changed listeners.
//! * Actions: global capture → window capture (root → focus) → window bubble (focus → root;
//!   bubble listeners stop propagation unless they call `cx.propagate()`) → global bubble.

const std = @import("std");
const input = @import("../input.zig");
const platform = @import("../platform/platform.zig");
const app_mod = @import("../app/app.zig");
const App = app_mod.App;
const dispatch_tree = @import("../app/dispatch_tree.zig");
const DispatchPhase = dispatch_tree.DispatchPhase;
const DispatchNodeId = dispatch_tree.DispatchNodeId;
const keymap_mod = @import("../app/keymap.zig");
const Keystroke = keymap_mod.Keystroke;
const AnyAction = @import("../app/action.zig").AnyAction;
const type_id = @import("../app/type_id.zig");
const window_mod = @import("window.zig");
const external_paths = @import("external_paths.zig");
const Window = window_mod.Window;
const WindowId = window_mod.WindowId;

pub const KeyEventKind = enum { key_down, key_up, modifiers_changed };

/// What key listeners receive as `event` (a typed event plus its kind).
pub const KeyEvent = struct {
    kind: KeyEventKind,
    event: *const anyopaque,
};

pub fn keyEventKind(comptime Ev: type) KeyEventKind {
    return switch (Ev) {
        input.KeyDownEvent => .key_down,
        input.KeyUpEvent => .key_up,
        input.ModifiersChangedEvent => .modifiers_changed,
        else => @compileError(@typeName(Ev) ++ " is not a key event"),
    };
}

/// Deliver a platform input event (gpui `Window::dispatch_event`).
pub fn dispatchEvent(w: *Window, event: input.PlatformInput) platform.DispatchEventResult {
    const app = w.app;
    app.startUpdate();
    defer app.finishUpdate();

    const was_keyboard = w.last_input_was_keyboard;
    switch (event) {
        .key_down => w.last_input_was_keyboard = true,
        .mouse_move, .mouse_down => w.last_input_was_keyboard = false,
        else => {},
    }
    if (w.last_input_was_keyboard != was_keyboard) w.refresh();

    app.propagate_event = true;
    w.default_prevented = false;

    switch (event) {
        .mouse_move => |e| {
            w.mouse_position = e.position;
            w.modifiers = e.modifiers;
            dispatchMouseEvent(w, .mouse_move, &e);
        },
        .mouse_down => |e| {
            w.mouse_position = e.position;
            w.modifiers = e.modifiers;
            dispatchMouseEvent(w, .mouse_down, &e);
        },
        .mouse_up => |e| {
            w.mouse_position = e.position;
            w.modifiers = e.modifiers;
            dispatchMouseEvent(w, .mouse_up, &e);
        },
        .mouse_exited => |e| {
            w.modifiers = e.modifiers;
            dispatchMouseEvent(w, .mouse_exited, &e);
        },
        .scroll_wheel => |e| {
            w.mouse_position = e.position;
            w.modifiers = e.modifiers;
            dispatchMouseEvent(w, .scroll_wheel, &e);
        },
        .file_drop => |fd| switch (fd) {
            // External drags become internal drags of `ExternalPaths` (gpui
            // `Window::dispatch_event`): drop targets use `onDrop(ExternalPaths, ..)`.
            .entered => |e| {
                w.mouse_position = e.position;
                external_paths.beginExternalDrag(app, e.paths, e.position);
                const mm: input.MouseMoveEvent = .{ .position = e.position, .pressed_button = .left };
                dispatchMouseEvent(w, .mouse_move, &mm);
            },
            .pending => |e| {
                w.mouse_position = e.position;
                const mm: input.MouseMoveEvent = .{ .position = e.position, .pressed_button = .left };
                dispatchMouseEvent(w, .mouse_move, &mm);
            },
            .submit => |e| {
                w.mouse_position = e.position;
                const mu: input.MouseUpEvent = .{ .button = .left, .position = e.position };
                dispatchMouseEvent(w, .mouse_up, &mu);
            },
            .exited => {
                app.cancelDrag();
                w.refresh();
            },
        },
        .key_down => |e| {
            const ke: KeyEvent = .{ .kind = .key_down, .event = &e };
            dispatchKeyEvent(w, ke, e.keystroke);
        },
        .key_up => |e| {
            const ke: KeyEvent = .{ .kind = .key_up, .event = &e };
            dispatchKeyEvent(w, ke, null);
        },
        .modifiers_changed => |e| {
            w.modifiers = e.modifiers;
            w.capslock = e.capslock;
            const ke: KeyEvent = .{ .kind = .modifiers_changed, .event = &e };
            dispatchKeyEvent(w, ke, null);
        },
    }
    return .{ .propagate = app.propagate_event, .default_prevented = w.default_prevented };
}

fn dispatchMouseEvent(w: *Window, kind: window_mod.MouseEventKind, event: *const anyopaque) void {
    const app = w.app;
    var hit: window_mod.HitTest = .{};
    w.rendered_frame.hitTest(w.mouse_position, &hit);
    if (!hit.eql(&w.mouse_hit_test)) {
        std.mem.swap(window_mod.HitTest, &hit, &w.mouse_hit_test);
        resetCursor(w);
    }
    hit.ids.deinit(w.gpa);

    var listeners = w.rendered_frame.mouse_listeners;
    w.rendered_frame.mouse_listeners = .empty;
    defer {
        w.rendered_frame.mouse_listeners.deinit(w.gpa);
        w.rendered_frame.mouse_listeners = listeners;
    }

    for (listeners.items) |*slot| {
        const l = &(slot.* orelse continue);
        if (l.kind != kind) continue;
        l.func(&l.cap, event, .capture, w, app);
        if (!app.propagate_event) break;
    }
    if (app.propagate_event) {
        var i = listeners.items.len;
        while (i > 0) {
            i -= 1;
            const l = &(listeners.items[i] orelse continue);
            if (l.kind != kind) continue;
            l.func(&l.cap, event, .bubble, w, app);
            if (!app.propagate_event) break;
        }
    }

    if (app.active_drag != null) {
        if (kind == .mouse_move) {
            w.refresh();
        } else if (kind == .mouse_up) {
            app.cancelDrag();
            w.refresh();
        }
    }
    if (kind == .mouse_up and w.captured_hitbox != null) w.captured_hitbox = null;
}

fn resetCursor(w: *Window) void {
    // Same rule as Window.resetCursorStyle (kept private there).
    if (!w.hovered and !w.active) return;
    var i = w.rendered_frame.cursor_styles.items.len;
    var style: platform.CursorStyle = .arrow;
    while (i > 0) {
        i -= 1;
        const r = w.rendered_frame.cursor_styles.items[i];
        if (r.hitbox_id) |h| {
            if (h.isHovered(w)) {
                style = r.style;
                break;
            }
        } else {
            style = r.style;
            break;
        }
    }
    w.app.platform.setCursorStyle(style);
}

fn focusNodeId(w: *Window) ?DispatchNodeId {
    const tree = &w.rendered_frame.dispatch_tree;
    if (tree.len() == 0) return null;
    if (w.focused_id) |f| if (tree.focusableNodeId(f)) |n| return n;
    return tree.rootNodeId();
}

fn modifierCount(m: input.Modifiers) u32 {
    return @as(u32, @intFromBool(m.control)) + @intFromBool(m.alt) + @intFromBool(m.shift) + @intFromBool(m.platform) + @intFromBool(m.function);
}

fn dispatchKeyEvent(w: *Window, kev: KeyEvent, key_down_stroke: ?input.Keystroke) void {
    const app = w.app;
    const gpa = w.gpa;
    if (w.dirty) {
        w.draw();
        w.element_arena.clear();
    }
    const node_id = focusNodeId(w) orelse return;
    var path = w.rendered_frame.dispatch_tree.dispatchPath(gpa, node_id) catch @panic("OOM");
    defer path.deinit(gpa);

    var keystroke: ?Keystroke = null;
    if (kev.kind == .modifiers_changed) {
        const e: *const input.ModifiersChangedEvent = @ptrCast(@alignCast(kev.event));
        const pm = &w.pending_modifier;
        if (modifierCount(e.modifiers) == 0 and modifierCount(pm.modifiers) == 1 and !pm.saw_keystroke) {
            const m = pm.modifiers;
            const key: ?[]const u8 = if (m.shift) "shift" else if (m.control) "control" else if (m.alt) "alt" else if (m.platform) "platform" else if (m.function) "function" else null;
            if (key) |k| keystroke = .{ .key = k };
        }
        if (modifierCount(pm.modifiers) == 0 and modifierCount(e.modifiers) == 1) pm.saw_keystroke = false;
        pm.modifiers = e.modifiers;
    } else if (key_down_stroke) |ks| {
        w.pending_modifier.saw_keystroke = true;
        keystroke = ks;
    }

    const ks = keystroke orelse {
        finishDispatchKeyEvent(w, kev, path.items);
        return;
    };

    app.propagate_event = true;
    if (w.pending_input.focus != null and w.pending_input.focus != w.focused_id) w.pending_input.clear(gpa);

    var result = w.rendered_frame.dispatch_tree.dispatchKey(gpa, w.pending_input.keystrokes.items, ks, path.items) catch @panic("OOM");
    defer result.deinit(gpa);

    if (result.to_replay.items.len > 0) {
        replayPendingInput(w, result.to_replay.items);
        app.propagate_event = true;
    }

    if (result.pending.items.len > 0) {
        w.pending_input.timer.cancel();
        w.pending_input.set(gpa, result.pending.items) catch @panic("OOM");
        w.pending_input.focus = w.focused_id;
        const text_input_requires_timeout = kev.kind == .key_down and ks.key_char != null and w.input_handler != null;
        w.pending_input.needs_timeout = w.pending_input.needs_timeout or result.pending_has_binding or text_input_requires_timeout;
        if (w.pending_input.needs_timeout) {
            w.pending_input.timer = app.foregroundExecutor().timer(dispatch_tree.PendingInput.timeout_ns, PendingTimeout{ .app = app, .window = w.id }) catch @panic("OOM");
        }
        app.propagate_event = false;
        return;
    }
    // Pending input is consumed (or abandoned and replayed above).
    w.pending_input.clear(gpa);

    var skip_bindings = false;
    if (kev.kind == .key_down) {
        const e: *const input.KeyDownEvent = @ptrCast(@alignCast(kev.event));
        skip_bindings = e.prefer_character_input and w.input_handler != null;
    }
    if (!skip_bindings) {
        for (result.bindings.items) |b| {
            dispatchActionOnNode(w, node_id, &b.action);
            if (!app.propagate_event) return;
        }
    }
    finishDispatchKeyEvent(w, kev, path.items);
}

const PendingTimeout = struct {
    app: *App,
    window: WindowId,

    pub fn finish(self: *PendingTimeout) void {
        const app = self.app;
        const w = app.windowById(self.window) orelse return;
        w.pending_input.timer.detach();
        if (w.pending_input.focus != w.focused_id or w.pending_input.isEmpty()) {
            w.pending_input.clear(w.gpa);
            return;
        }
        app.startUpdate();
        defer app.finishUpdate();
        const node_id = focusNodeId(w) orelse return;
        var path = w.rendered_frame.dispatch_tree.dispatchPath(w.gpa, node_id) catch @panic("OOM");
        defer path.deinit(w.gpa);
        var replays = w.rendered_frame.dispatch_tree.flushDispatch(w.gpa, w.pending_input.keystrokes.items, path.items) catch @panic("OOM");
        defer dispatch_tree.deinitReplays(w.gpa, &replays);
        // Keep the keystroke memory alive until replay finishes.
        var keys = w.pending_input.keystrokes;
        w.pending_input.keystrokes = .empty;
        defer {
            for (keys.items) |k| keymap_mod.freeKeystroke(w.gpa, k);
            keys.deinit(w.gpa);
        }
        w.pending_input.clear(w.gpa);
        replayPendingInput(w, replays.items);
    }
};

fn replayPendingInput(w: *Window, replays: []const dispatch_tree.Replay) void {
    const app = w.app;
    const node_id = focusNodeId(w) orelse return;
    var path = w.rendered_frame.dispatch_tree.dispatchPath(w.gpa, node_id) catch @panic("OOM");
    defer path.deinit(w.gpa);
    replay: for (replays) |r| {
        const ev: input.KeyDownEvent = .{ .keystroke = r.keystroke, .prefer_character_input = true };
        app.propagate_event = true;
        for (r.bindings.items) |b| {
            dispatchActionOnNode(w, node_id, &b.action);
            if (!app.propagate_event) continue :replay;
        }
        dispatchKeyDownUp(w, .{ .kind = .key_down, .event = &ev }, path.items);
        if (!app.propagate_event) continue;
        if (r.keystroke.key_char) |text| if (w.input_handler) |h| h.replaceTextInRange(w, null, text);
    }
}

fn finishDispatchKeyEvent(w: *Window, kev: KeyEvent, path: []const DispatchNodeId) void {
    dispatchKeyDownUp(w, kev, path);
    if (!w.app.propagate_event) return;
    if (kev.kind == .modifiers_changed) {
        const app = w.app;
        var i = path.len;
        while (i > 0) {
            i -= 1;
            var j: usize = 0;
            while (j < w.rendered_frame.dispatch_tree.node(path[i]).modifiers_changed_listeners.items.len) : (j += 1) {
                const l = w.rendered_frame.dispatch_tree.node(path[i]).modifiers_changed_listeners.items[j];
                l.func(&l, kev.event, w, app);
                if (!app.propagate_event) return;
            }
        }
    }
}

fn dispatchKeyDownUp(w: *Window, kev: KeyEvent, path: []const DispatchNodeId) void {
    if (kev.kind == .modifiers_changed) return;
    const app = w.app;
    for (path) |id| {
        var j: usize = 0;
        while (j < w.rendered_frame.dispatch_tree.node(id).key_listeners.items.len) : (j += 1) {
            const l = w.rendered_frame.dispatch_tree.node(id).key_listeners.items[j];
            l.func(&l, &kev, .capture, w, app);
            if (!app.propagate_event) return;
        }
    }
    var i = path.len;
    while (i > 0) {
        i -= 1;
        var j: usize = 0;
        while (j < w.rendered_frame.dispatch_tree.node(path[i]).key_listeners.items.len) : (j += 1) {
            const l = w.rendered_frame.dispatch_tree.node(path[i]).key_listeners.items[j];
            l.func(&l, &kev, .bubble, w, app);
            if (!app.propagate_event) return;
        }
    }
}

/// gpui `dispatch_action_on_node`.
pub fn dispatchActionOnNode(w: *Window, node_id: DispatchNodeId, action: *const AnyAction) void {
    const app = w.app;
    var path = w.rendered_frame.dispatch_tree.dispatchPath(w.gpa, node_id) catch @panic("OOM");
    defer path.deinit(w.gpa);

    app.propagate_event = true;
    app.dispatchGlobalAction(action, .capture);
    if (!app.propagate_event) return;

    for (path.items) |id| {
        var j: usize = 0;
        while (j < w.rendered_frame.dispatch_tree.node(id).action_listeners.items.len) : (j += 1) {
            const l = w.rendered_frame.dispatch_tree.node(id).action_listeners.items[j];
            if (l.action_type != action.type_id) continue;
            l.func(&l, action, .capture, w, app);
            if (!app.propagate_event) return;
        }
    }
    var i = path.items.len;
    while (i > 0) {
        i -= 1;
        var j: usize = 0;
        while (j < w.rendered_frame.dispatch_tree.node(path.items[i]).action_listeners.items.len) : (j += 1) {
            const l = w.rendered_frame.dispatch_tree.node(path.items[i]).action_listeners.items[j];
            if (l.action_type != action.type_id) continue;
            app.propagate_event = false;
            l.func(&l, action, .bubble, w, app);
            if (!app.propagate_event) return;
        }
    }
    app.dispatchGlobalAction(action, .bubble);
}

/// Dispatch `action` (any action value) from the focused element (gpui `dispatch_action`).
pub fn dispatchAction(w: *Window, action: anytype) void {
    var any = AnyAction.init(w.gpa, action) catch @panic("OOM");
    defer any.deinit(w.gpa);
    dispatchAnyAction(w, &any);
}

pub fn dispatchAnyAction(w: *Window, action: *const AnyAction) void {
    const app = w.app;
    app.startUpdate();
    defer app.finishUpdate();
    if (w.dirty) {
        w.draw();
        w.element_arena.clear();
    }
    const node_id = focusNodeId(w) orelse {
        app.propagate_event = true;
        app.dispatchGlobalAction(action, .capture);
        if (app.propagate_event) app.dispatchGlobalAction(action, .bubble);
        return;
    };
    dispatchActionOnNode(w, node_id, action);
}

/// Whether some listener on the focus path (or a global one) handles action type `A`.
pub fn isActionAvailable(w: *Window, comptime A: type) bool {
    const tid = type_id.typeId(A);
    if (w.app.global_action_listeners.contains(type_id.key(tid))) return true;
    const node_id = focusNodeId(w) orelse return false;
    return w.rendered_frame.dispatch_tree.isActionAvailable(tid, node_id);
}

/// Runtime-typed `isActionAvailable` (menu validation, `App.isActionAvailable`).
pub fn isActionTypeAvailable(w: *Window, tid: type_id.TypeId) bool {
    if (w.app.global_action_listeners.contains(type_id.key(tid))) return true;
    const node_id = focusNodeId(w) orelse return false;
    return w.rendered_frame.dispatch_tree.isActionAvailable(tid, node_id);
}

pub fn hasPendingKeystrokes(w: *const Window) bool {
    return !w.pending_input.isEmpty();
}

pub fn pendingKeystrokes(w: *const Window) []const Keystroke {
    return w.pending_input.keystrokes.items;
}
