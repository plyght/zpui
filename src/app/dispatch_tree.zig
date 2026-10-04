//! DispatchTree skeleton (gpui `key_dispatch.rs`): the per-frame tree of key contexts,
//! focus ids and action/key listeners that the window builds while painting, plus the
//! keystroke matching algorithm (pending multi-stroke input, replay, timeout flush).
//!
//! The window phase owns two trees (rendered / next frame), pushes one node per element
//! (`pushNode` / `popNode`), and on key-down calls `dispatchKey(pending, keystroke, path)`
//! where `path = dispatchPath(focused node)`. Results tell it which bindings to dispatch,
//! what to keep pending (arming a `PendingInput.timeout_ns` timer when needed) and which
//! keystrokes to replay because a longer binding did not materialize.
//!
//! Listener contexts and KeyContext strings are borrowed (frame arena); the tree only owns
//! its node arrays.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("app.zig").App;
const EntityId = @import("entity.zig").EntityId;
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const keymap_mod = @import("keymap.zig");
const Keymap = keymap_mod.Keymap;
const KeyBinding = keymap_mod.KeyBinding;
const Keystroke = keymap_mod.Keystroke;
const KeyContext = @import("key_context.zig").KeyContext;
const AnyAction = @import("action.zig").AnyAction;
const executor = @import("executor.zig");

/// Identifies a focusable element (gpui `FocusId`); allocated by the focus map (window phase).
pub const FocusId = enum(u64) { _ };

/// Index of a node in one frame's tree. Not stable across frames.
pub const DispatchNodeId = enum(u32) {
    _,
    pub fn index(id: DispatchNodeId) usize {
        return @backingInt(id);
    }
    fn of(i: usize) DispatchNodeId {
        return @fromBackingInt(@intCast(i));
    }
};

pub const DispatchPhase = enum {
    /// Root → target.
    capture,
    /// Target → root (default for listeners).
    bubble,
};

/// `window` is `*Window` once the window phase exists.
pub const ActionListener = struct {
    action_type: TypeId,
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, action: *const AnyAction, phase: DispatchPhase, window: ?*anyopaque, app: *App) void,
};

/// Raw key down/up listener. `event` points at a `input.KeyDownEvent` or `input.KeyUpEvent`.
pub const KeyListener = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: *const anyopaque, phase: DispatchPhase, window: ?*anyopaque, app: *App) void,
};

pub const ModifiersChangedListener = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: *const anyopaque, window: ?*anyopaque, app: *App) void,
};

pub const DispatchNode = struct {
    key_listeners: std.ArrayList(KeyListener) = .empty,
    action_listeners: std.ArrayList(ActionListener) = .empty,
    modifiers_changed_listeners: std.ArrayList(ModifiersChangedListener) = .empty,
    context: ?KeyContext = null,
    focus_id: ?FocusId = null,
    view_id: ?EntityId = null,
    parent: ?DispatchNodeId = null,

    fn deinit(self: *DispatchNode, gpa: Allocator) void {
        self.key_listeners.deinit(gpa);
        self.action_listeners.deinit(gpa);
        self.modifiers_changed_listeners.deinit(gpa);
    }
};

/// One keystroke to re-dispatch, with the bindings it matches on its own (maybe none, in
/// which case it goes to the input handler as text).
pub const Replay = struct {
    keystroke: Keystroke,
    bindings: std.ArrayList(*const KeyBinding) = .empty,
};

pub const DispatchResult = struct {
    /// New pending input (non-empty ⇒ wait for more keys).
    pending: std.ArrayList(Keystroke) = .empty,
    /// Some binding matched the pending input exactly (so a timeout should dispatch it).
    pending_has_binding: bool = false,
    /// Bindings to dispatch now, highest precedence first.
    bindings: std.ArrayList(*const KeyBinding) = .empty,
    /// Previously pending keystrokes to replay first.
    to_replay: std.ArrayList(Replay) = .empty,
    /// Contexts along the dispatch path (shallow copies; valid while the tree is).
    context_stack: std.ArrayList(KeyContext) = .empty,

    pub fn deinit(self: *DispatchResult, gpa: Allocator) void {
        self.pending.deinit(gpa);
        self.bindings.deinit(gpa);
        for (self.to_replay.items) |*r| r.bindings.deinit(gpa);
        self.to_replay.deinit(gpa);
        self.context_stack.deinit(gpa);
    }
};

pub fn deinitReplays(gpa: Allocator, list: *std.ArrayList(Replay)) void {
    for (list.items) |*r| r.bindings.deinit(gpa);
    list.deinit(gpa);
}

pub const ReusedSubtree = struct {
    old_start: usize,
    new_start: usize,
    len: usize,
    contains_focus: bool,

    pub fn refreshNodeId(self: ReusedSubtree, id: DispatchNodeId) DispatchNodeId {
        std.debug.assert(id.index() >= self.old_start and id.index() < self.old_start + self.len);
        return .of(id.index() - self.old_start + self.new_start);
    }
};

pub const DispatchTree = struct {
    gpa: Allocator,
    keymap: *const Keymap,
    nodes: std.ArrayList(DispatchNode) = .empty,
    node_stack: std.ArrayList(DispatchNodeId) = .empty,
    context_stack: std.ArrayList(KeyContext) = .empty,
    view_stack: std.ArrayList(EntityId) = .empty,
    focusable_node_ids: std.AutoHashMapUnmanaged(FocusId, DispatchNodeId) = .empty,
    view_node_ids: std.AutoHashMapUnmanaged(EntityId, DispatchNodeId) = .empty,

    pub fn init(gpa: Allocator, keymap: *const Keymap) DispatchTree {
        return .{ .gpa = gpa, .keymap = keymap };
    }

    pub fn deinit(self: *DispatchTree) void {
        for (self.nodes.items) |*n| n.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.node_stack.deinit(self.gpa);
        self.context_stack.deinit(self.gpa);
        self.view_stack.deinit(self.gpa);
        self.focusable_node_ids.deinit(self.gpa);
        self.view_node_ids.deinit(self.gpa);
    }

    pub fn clear(self: *DispatchTree) void {
        for (self.nodes.items) |*n| n.deinit(self.gpa);
        self.nodes.clearRetainingCapacity();
        self.node_stack.clearRetainingCapacity();
        self.context_stack.clearRetainingCapacity();
        self.view_stack.clearRetainingCapacity();
        self.focusable_node_ids.clearRetainingCapacity();
        self.view_node_ids.clearRetainingCapacity();
    }

    pub fn len(self: *const DispatchTree) usize {
        return self.nodes.items.len;
    }

    pub fn node(self: *const DispatchTree, id: DispatchNodeId) *const DispatchNode {
        return &self.nodes.items[id.index()];
    }

    pub fn activeNodeId(self: *const DispatchTree) ?DispatchNodeId {
        return if (self.node_stack.items.len == 0) null else self.node_stack.items[self.node_stack.items.len - 1];
    }

    fn activeNode(self: *DispatchTree) *DispatchNode {
        return &self.nodes.items[self.activeNodeId().?.index()];
    }

    pub fn rootNodeId(self: *const DispatchTree) DispatchNodeId {
        std.debug.assert(self.nodes.items.len > 0);
        return .of(0);
    }

    pub fn pushNode(self: *DispatchTree) Allocator.Error!DispatchNodeId {
        const id: DispatchNodeId = .of(self.nodes.items.len);
        try self.node_stack.ensureUnusedCapacity(self.gpa, 1);
        try self.nodes.append(self.gpa, .{ .parent = self.activeNodeId() });
        self.node_stack.appendAssumeCapacity(id);
        return id;
    }

    pub fn popNode(self: *DispatchTree) void {
        const n = self.node(self.activeNodeId().?);
        if (n.context != null) _ = self.context_stack.pop();
        if (n.view_id != null) _ = self.view_stack.pop();
        _ = self.node_stack.pop();
    }

    /// Re-enter an existing node (used when painting after prepaint).
    pub fn setActiveNode(self: *DispatchTree, id: DispatchNodeId) Allocator.Error!void {
        const next_parent = self.nodes.items[id.index()].parent;
        while (self.node_stack.items.len > 0 and self.activeNodeId() != next_parent) self.popNode();

        if (self.activeNodeId() == next_parent) {
            try self.node_stack.append(self.gpa, id);
            const n = self.nodes.items[id.index()];
            if (n.view_id) |v| try self.view_stack.append(self.gpa, v);
            if (n.context) |c| try self.context_stack.append(self.gpa, c);
        } else {
            std.debug.assert(self.node_stack.items.len == 0);
            var current: ?DispatchNodeId = id;
            while (current) |cid| {
                const n = self.nodes.items[cid.index()];
                if (n.context) |c| try self.context_stack.append(self.gpa, c);
                if (n.view_id) |v| try self.view_stack.append(self.gpa, v);
                try self.node_stack.append(self.gpa, cid);
                current = n.parent;
            }
            std.mem.reverse(KeyContext, self.context_stack.items);
            std.mem.reverse(EntityId, self.view_stack.items);
            std.mem.reverse(DispatchNodeId, self.node_stack.items);
        }
    }

    /// Set the active node's key context (borrowed: must outlive the frame).
    pub fn setKeyContext(self: *DispatchTree, context: KeyContext) Allocator.Error!void {
        try self.context_stack.append(self.gpa, context);
        self.activeNode().context = context;
    }

    pub fn setFocusId(self: *DispatchTree, focus_id: FocusId) Allocator.Error!void {
        const id = self.activeNodeId().?;
        try self.focusable_node_ids.put(self.gpa, focus_id, id);
        self.nodes.items[id.index()].focus_id = focus_id;
    }

    pub fn setViewId(self: *DispatchTree, view_id: EntityId) Allocator.Error!void {
        if (self.view_stack.items.len > 0 and self.view_stack.items[self.view_stack.items.len - 1] == view_id) return;
        const id = self.activeNodeId().?;
        try self.view_node_ids.put(self.gpa, view_id, id);
        try self.view_stack.append(self.gpa, view_id);
        self.nodes.items[id.index()].view_id = view_id;
    }

    pub fn onAction(self: *DispatchTree, listener: ActionListener) Allocator.Error!void {
        try self.activeNode().action_listeners.append(self.gpa, listener);
    }

    pub fn onKeyEvent(self: *DispatchTree, listener: KeyListener) Allocator.Error!void {
        try self.activeNode().key_listeners.append(self.gpa, listener);
    }

    pub fn onModifiersChanged(self: *DispatchTree, listener: ModifiersChangedListener) Allocator.Error!void {
        try self.activeNode().modifiers_changed_listeners.append(self.gpa, listener);
    }

    fn moveNode(self: *DispatchTree, source: *DispatchNode) Allocator.Error!void {
        _ = try self.pushNode();
        if (source.context) |c| try self.setKeyContext(c);
        if (source.focus_id) |f| try self.setFocusId(f);
        if (source.view_id) |v| try self.setViewId(v);
        const target = self.activeNode();
        target.key_listeners.deinit(self.gpa);
        target.action_listeners.deinit(self.gpa);
        target.modifiers_changed_listeners.deinit(self.gpa);
        target.key_listeners = source.key_listeners;
        target.action_listeners = source.action_listeners;
        target.modifiers_changed_listeners = source.modifiers_changed_listeners;
        source.key_listeners = .empty;
        source.action_listeners = .empty;
        source.modifiers_changed_listeners = .empty;
    }

    /// Move nodes `[old_start, old_start+count)` of `source` (a cached view's subtree from the
    /// previous frame) under the current active node.
    pub fn reuseSubtree(self: *DispatchTree, old_start: usize, count: usize, source: *DispatchTree, focus: ?FocusId) Allocator.Error!ReusedSubtree {
        const new_start = self.nodes.items.len;
        var contains_focus = false;
        var source_stack: std.ArrayList(DispatchNodeId) = .empty;
        defer source_stack.deinit(self.gpa);
        for (old_start..old_start + count) |i| {
            const src = &source.nodes.items[i];
            while (source_stack.items.len > 0) {
                const top = source_stack.items[source_stack.items.len - 1];
                if (src.parent == top) break;
                _ = source_stack.pop();
                self.popNode();
            }
            try source_stack.append(self.gpa, .of(i));
            if (src.focus_id != null and src.focus_id == focus) contains_focus = true;
            try self.moveNode(src);
        }
        while (source_stack.pop()) |_| self.popNode();
        return .{ .old_start = old_start, .new_start = new_start, .len = count, .contains_focus = contains_focus };
    }

    /// Drop nodes from `index` on (e.g. when a prepaint is rolled back).
    pub fn truncate(self: *DispatchTree, index: usize) void {
        for (self.nodes.items[index..]) |*n| {
            if (n.focus_id) |f| _ = self.focusable_node_ids.remove(f);
            if (n.view_id) |v| _ = self.view_node_ids.remove(v);
            n.deinit(self.gpa);
        }
        self.nodes.shrinkRetainingCapacity(index);
    }

    // ---- queries ---------------------------------------------------------------------

    /// Node ids from the root to `target` (inclusive).
    pub fn dispatchPath(self: *const DispatchTree, gpa: Allocator, target: DispatchNodeId) Allocator.Error!std.ArrayList(DispatchNodeId) {
        var path: std.ArrayList(DispatchNodeId) = .empty;
        errdefer path.deinit(gpa);
        var current: ?DispatchNodeId = target;
        while (current) |id| {
            if (id.index() >= self.nodes.items.len) break;
            try path.append(gpa, id);
            current = self.nodes.items[id.index()].parent;
        }
        std.mem.reverse(DispatchNodeId, path.items);
        return path;
    }

    /// Focus ids from the root to `focus_id`.
    pub fn focusPath(self: *const DispatchTree, gpa: Allocator, focus_id: FocusId) Allocator.Error!std.ArrayList(FocusId) {
        var path: std.ArrayList(FocusId) = .empty;
        errdefer path.deinit(gpa);
        var current = self.focusable_node_ids.get(focus_id);
        while (current) |id| {
            const n = self.node(id);
            if (n.focus_id) |f| try path.append(gpa, f);
            current = n.parent;
        }
        std.mem.reverse(FocusId, path.items);
        return path;
    }

    /// View ids from `view_id` up to the root (gpui `view_path_reversed`).
    pub fn viewPathReversed(self: *const DispatchTree, gpa: Allocator, view_id: EntityId) Allocator.Error!std.ArrayList(EntityId) {
        var out: std.ArrayList(EntityId) = .empty;
        errdefer out.deinit(gpa);
        var current = self.view_node_ids.get(view_id);
        while (current) |id| {
            const n = self.node(id);
            if (n.view_id) |v| try out.append(gpa, v);
            current = n.parent;
        }
        return out;
    }

    pub fn focusableNodeId(self: *const DispatchTree, focus_id: FocusId) ?DispatchNodeId {
        return self.focusable_node_ids.get(focus_id);
    }

    pub fn focusContains(self: *const DispatchTree, parent: FocusId, child: FocusId) bool {
        if (parent == child) return true;
        const parent_node = self.focusable_node_ids.get(parent) orelse return false;
        var current = self.focusable_node_ids.get(child);
        while (current) |id| {
            if (id == parent_node) return true;
            current = self.node(id).parent;
        }
        return false;
    }

    pub fn isActionAvailable(self: *const DispatchTree, action_type: TypeId, target: DispatchNodeId) bool {
        var current: ?DispatchNodeId = target;
        while (current) |id| {
            const n = self.node(id);
            for (n.action_listeners.items) |l| if (l.action_type == action_type) return true;
            current = n.parent;
        }
        return false;
    }

    /// Distinct action types with listeners on the path to `target`.
    pub fn availableActionTypes(self: *const DispatchTree, gpa: Allocator, target: DispatchNodeId) Allocator.Error!std.ArrayList(TypeId) {
        var out: std.ArrayList(TypeId) = .empty;
        errdefer out.deinit(gpa);
        var current: ?DispatchNodeId = target;
        while (current) |id| {
            const n = self.node(id);
            outer: for (n.action_listeners.items) |l| {
                for (out.items) |t| if (t == l.action_type) continue :outer;
                try out.append(gpa, l.action_type);
            }
            current = n.parent;
        }
        return out;
    }

    /// Contexts along `path` (shallow copies).
    pub fn contextStackFor(self: *const DispatchTree, gpa: Allocator, path: []const DispatchNodeId) Allocator.Error!std.ArrayList(KeyContext) {
        var out: std.ArrayList(KeyContext) = .empty;
        errdefer out.deinit(gpa);
        for (path) |id| if (self.node(id).context) |c| try out.append(gpa, c);
        return out;
    }

    fn bindingMatchesAndNotShadowed(self: *const DispatchTree, gpa: Allocator, b: *const KeyBinding, contexts: []const KeyContext) Allocator.Error!bool {
        var m = try self.keymap.bindingsForInput(gpa, b.keystrokes, contexts);
        defer m.deinit(gpa);
        if (m.bindings.items.len == 0) return false;
        return m.bindings.items[0].action.eql(b.action);
    }

    /// Bindings that would dispatch `action` in `contexts` and are not shadowed (insertion
    /// order; the last one has the highest precedence, for display).
    pub fn bindingsForAction(self: *const DispatchTree, gpa: Allocator, action: AnyAction, contexts: []const KeyContext) Allocator.Error!std.ArrayList(*const KeyBinding) {
        var all = try self.keymap.bindingsForAction(gpa, action);
        errdefer all.deinit(gpa);
        var w: usize = 0;
        for (all.items) |b| {
            if (try self.bindingMatchesAndNotShadowed(gpa, b, contexts)) {
                all.items[w] = b;
                w += 1;
            }
        }
        all.shrinkRetainingCapacity(w);
        return all;
    }

    pub fn highestPrecedenceBindingForAction(self: *const DispatchTree, gpa: Allocator, action: AnyAction, contexts: []const KeyContext) Allocator.Error!?*const KeyBinding {
        var all = try self.keymap.bindingsForAction(gpa, action);
        defer all.deinit(gpa);
        var i = all.items.len;
        while (i > 0) {
            i -= 1;
            if (try self.bindingMatchesAndNotShadowed(gpa, all.items[i], contexts)) return all.items[i];
        }
        return null;
    }

    // ---- keystroke matching ----------------------------------------------------------

    fn bindingsForInput(self: *const DispatchTree, gpa: Allocator, input: []const Keystroke, contexts: []const KeyContext) Allocator.Error!Keymap.Match {
        return self.keymap.bindingsForInput(gpa, input, contexts);
    }

    /// gpui `dispatch_key`. `pending` is the pending input from the previous call.
    pub fn dispatchKey(self: *const DispatchTree, gpa: Allocator, pending: []const Keystroke, keystroke: Keystroke, path: []const DispatchNodeId) Allocator.Error!DispatchResult {
        var contexts = try self.contextStackFor(gpa, path);
        errdefer contexts.deinit(gpa);
        var result = try self.dispatchKeyInner(gpa, pending, keystroke, contexts.items);
        result.context_stack.deinit(gpa);
        result.context_stack = contexts;
        return result;
    }

    fn dispatchKeyInner(self: *const DispatchTree, gpa: Allocator, pending: []const Keystroke, keystroke: Keystroke, contexts: []const KeyContext) Allocator.Error!DispatchResult {
        var input: std.ArrayList(Keystroke) = .empty;
        defer input.deinit(gpa);
        try input.appendSlice(gpa, pending);
        try input.append(gpa, keystroke);

        var m = try self.bindingsForInput(gpa, input.items, contexts);
        errdefer m.deinit(gpa);
        var result: DispatchResult = .{};
        errdefer result.deinit(gpa);
        if (m.pending) {
            result.pending = input;
            input = .empty;
            result.pending_has_binding = m.bindings.items.len != 0;
            m.deinit(gpa);
            return result;
        }
        if (m.bindings.items.len != 0) {
            result.bindings = m.bindings;
            return result;
        }
        m.deinit(gpa);
        if (input.items.len == 1) return result;

        // The pending prefix no longer leads anywhere: replay its longest bound prefix and
        // retry with what remains.
        _ = input.pop();
        var to_replay: std.ArrayList(Replay) = .empty;
        errdefer deinitReplays(gpa, &to_replay);
        const suffix = try self.replayPrefix(gpa, input.items, contexts, &to_replay);
        var inner = try self.dispatchKeyInner(gpa, suffix, keystroke, contexts);
        errdefer inner.deinit(gpa);
        try to_replay.appendSlice(gpa, inner.to_replay.items);
        inner.to_replay.deinit(gpa);
        inner.to_replay = to_replay;
        return inner;
    }

    /// After the pending-input timeout: convert all pending keystrokes into replays.
    pub fn flushDispatch(self: *const DispatchTree, gpa: Allocator, pending: []const Keystroke, path: []const DispatchNodeId) Allocator.Error!std.ArrayList(Replay) {
        var contexts = try self.contextStackFor(gpa, path);
        defer contexts.deinit(gpa);
        var out: std.ArrayList(Replay) = .empty;
        errdefer deinitReplays(gpa, &out);
        var rest = pending;
        while (rest.len > 0) rest = try self.replayPrefix(gpa, rest, contexts.items, &out);
        return out;
    }

    /// Append a replay for the longest prefix of `input` that has bindings (or just its first
    /// keystroke, unbound) and return the remaining suffix.
    fn replayPrefix(self: *const DispatchTree, gpa: Allocator, input: []const Keystroke, contexts: []const KeyContext, out: *std.ArrayList(Replay)) Allocator.Error![]const Keystroke {
        var last = input.len;
        while (last > 0) {
            last -= 1;
            var m = try self.bindingsForInput(gpa, input[0 .. last + 1], contexts);
            if (m.bindings.items.len != 0) {
                errdefer m.deinit(gpa);
                try out.append(gpa, .{ .keystroke = input[last], .bindings = m.bindings });
                return input[last + 1 ..];
            }
            m.deinit(gpa);
        }
        try out.append(gpa, .{ .keystroke = input[0] });
        return input[1..];
    }
};

/// Window-side pending multi-stroke state (gpui `PendingInput`). Owns copies of keystrokes.
pub const PendingInput = struct {
    keystrokes: std.ArrayList(Keystroke) = .empty,
    focus: ?FocusId = null,
    timer: executor.Task(void) = .none,
    needs_timeout: bool = false,

    /// gpui waits 1 s before flushing a pending prefix that is itself bound or that a text
    /// input would otherwise consume.
    pub const timeout_ns: u64 = std.time.ns_per_s;

    pub fn isEmpty(self: *const PendingInput) bool {
        return self.keystrokes.items.len == 0;
    }

    /// Replace the pending keystrokes with copies of `keys`.
    pub fn set(self: *PendingInput, gpa: Allocator, keys: []const Keystroke) Allocator.Error!void {
        self.freeKeys(gpa);
        for (keys) |k| try self.keystrokes.append(gpa, try keymap_mod.dupeKeystroke(gpa, k));
    }

    fn freeKeys(self: *PendingInput, gpa: Allocator) void {
        for (self.keystrokes.items) |k| keymap_mod.freeKeystroke(gpa, k);
        self.keystrokes.clearRetainingCapacity();
    }

    /// Drop pending keys and cancel the timer.
    pub fn clear(self: *PendingInput, gpa: Allocator) void {
        self.freeKeys(gpa);
        self.timer.cancel();
        self.focus = null;
        self.needs_timeout = false;
    }

    pub fn deinit(self: *PendingInput, gpa: Allocator) void {
        self.clear(gpa);
        self.keystrokes.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;
const action_mod = @import("action.zig");
const BindingSpec = keymap_mod.BindingSpec;
const Save = action_mod.action("test::Save");
const SaveAll = action_mod.action("test::SaveAll");
const Close = action_mod.action("test::Close");
const Find = action_mod.action("test::Find");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    keymap: Keymap,
    tree: DispatchTree,

    fn create(specs: []const BindingSpec) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .arena = .init(testing.allocator), .keymap = .init(testing.allocator), .tree = undefined };
        f.tree = .init(testing.allocator, &f.keymap);
        try f.keymap.addSpecs(specs);
        return f;
    }
    fn destroy(f: *Fixture) void {
        f.tree.deinit();
        f.keymap.deinit();
        f.arena.deinit();
        testing.allocator.destroy(f);
    }
    fn ctx(f: *Fixture, s: []const u8) KeyContext {
        return KeyContext.parse(f.arena.allocator(), s) catch unreachable;
    }
    fn key(f: *Fixture, s: []const u8) Keystroke {
        return keymap_mod.parseKeystroke(f.arena.allocator(), s) catch unreachable;
    }
    /// Workspace > Pane > Editor(focus 3), plus a sibling Terminal(focus 4) under Pane.
    fn buildStandard(f: *Fixture) !struct { workspace: DispatchNodeId, editor: DispatchNodeId, terminal: DispatchNodeId } {
        const t = &f.tree;
        const ws = try t.pushNode();
        try t.setKeyContext(f.ctx("Workspace"));
        try t.setFocusId(@fromBackingInt(@intCast(1)));
        _ = try t.pushNode();
        try t.setKeyContext(f.ctx("Pane"));
        try t.setFocusId(@fromBackingInt(@intCast(2)));
        const ed = try t.pushNode();
        try t.setKeyContext(f.ctx("Editor mode=full"));
        try t.setFocusId(@fromBackingInt(@intCast(3)));
        t.popNode();
        const term = try t.pushNode();
        try t.setKeyContext(f.ctx("Terminal"));
        try t.setFocusId(@fromBackingInt(@intCast(4)));
        t.popNode();
        t.popNode();
        t.popNode();
        return .{ .workspace = ws, .editor = ed, .terminal = term };
    }
};

fn noopAction(_: ?*anyopaque, _: *const AnyAction, _: DispatchPhase, _: ?*anyopaque, _: *App) void {}

test "DispatchTree: paths, focus containment, context stacks" {
    const f = try Fixture.create(&.{});
    defer f.destroy();
    const ids = try f.buildStandard();
    const t = &f.tree;
    try testing.expectEqual(@as(usize, 4), t.len());
    try testing.expectEqual(@as(usize, 0), t.node_stack.items.len);
    try testing.expectEqual(@as(usize, 0), t.context_stack.items.len);

    var path = try t.dispatchPath(testing.allocator, ids.editor);
    defer path.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), path.items.len);
    try testing.expectEqual(ids.workspace, path.items[0]);

    var ctxs = try t.contextStackFor(testing.allocator, path.items);
    defer ctxs.deinit(testing.allocator);
    try testing.expectEqualStrings("Editor", ctxs.items[2].primary().?.key);

    var fp = try t.focusPath(testing.allocator, @fromBackingInt(@intCast(3)));
    defer fp.deinit(testing.allocator);
    try testing.expectEqualSlices(FocusId, &.{ @fromBackingInt(@intCast(1)), @fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(3)) }, fp.items);
    try testing.expect(t.focusContains(@fromBackingInt(@intCast(1)), @fromBackingInt(@intCast(4))));
    try testing.expect(t.focusContains(@fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(3))));
    try testing.expect(!t.focusContains(@fromBackingInt(@intCast(3)), @fromBackingInt(@intCast(4))));
    try testing.expect(!t.focusContains(@fromBackingInt(@intCast(4)), @fromBackingInt(@intCast(2))));
    try testing.expectEqual(ids.terminal, t.focusableNodeId(@fromBackingInt(@intCast(4))).?);

    // Re-entering a node restores the stacks.
    try t.setActiveNode(ids.editor);
    try testing.expectEqual(@as(usize, 3), t.context_stack.items.len);
    try t.setActiveNode(ids.terminal);
    try testing.expectEqual(@as(usize, 3), t.node_stack.items.len);
    try testing.expectEqualStrings("Terminal", t.context_stack.items[2].primary().?.key);
}

test "DispatchTree: views and action availability" {
    const f = try Fixture.create(&.{});
    defer f.destroy();
    const t = &f.tree;
    const view_a: EntityId = .init(1, 1);
    const view_b: EntityId = .init(2, 1);
    _ = try t.pushNode();
    try t.setViewId(view_a);
    try t.onAction(.{ .action_type = type_id.typeId(Save), .func = noopAction });
    _ = try t.pushNode();
    try t.setViewId(view_a); // same view: not re-pushed
    const inner = try t.pushNode();
    try t.setViewId(view_b);
    try t.onAction(.{ .action_type = type_id.typeId(Close), .func = noopAction });
    try t.onAction(.{ .action_type = type_id.typeId(Save), .func = noopAction });
    t.popNode();
    t.popNode();
    t.popNode();

    var vp = try t.viewPathReversed(testing.allocator, view_b);
    defer vp.deinit(testing.allocator);
    try testing.expectEqualSlices(EntityId, &.{ view_b, view_a }, vp.items);
    try testing.expect(t.isActionAvailable(type_id.typeId(Save), inner));
    try testing.expect(t.isActionAvailable(type_id.typeId(Close), inner));
    try testing.expect(!t.isActionAvailable(type_id.typeId(Close), t.rootNodeId()));
    try testing.expect(!t.isActionAvailable(type_id.typeId(Find), inner));
    var avail = try t.availableActionTypes(testing.allocator, inner);
    defer avail.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), avail.items.len);
}

test "dispatchKey: single binding, context precedence" {
    const f = try Fixture.create(&.{
        .init("cmd-s", Save{}, "Workspace"),
        .init("cmd-s", SaveAll{}, "Editor"),
        .init("cmd-w", Close{}, "Terminal"),
    });
    defer f.destroy();
    const ids = try f.buildStandard();
    const gpa = testing.allocator;
    var path = try f.tree.dispatchPath(gpa, ids.editor);
    defer path.deinit(gpa);

    var r = try f.tree.dispatchKey(gpa, &.{}, f.key("cmd-s"), path.items);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.pending.items.len);
    try testing.expectEqual(@as(usize, 2), r.bindings.items.len);
    try testing.expect(r.bindings.items[0].action.is(SaveAll));
    try testing.expectEqual(@as(usize, 3), r.context_stack.items.len);

    var r2 = try f.tree.dispatchKey(gpa, &.{}, f.key("cmd-w"), path.items);
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r2.bindings.items.len);
}

test "dispatchKey: multi-stroke pending, completion, and replay" {
    const f = try Fixture.create(&.{
        // Prefix bindings must be added before the chord, or the later exact match
        // overrides the pending prefix (gpui test_overriding_prefix).
        .init("cmd-k", Find{}, "Editor"),
        .init("cmd-k cmd-s", SaveAll{}, null),
        .init("x", Close{}, null),
    });
    defer f.destroy();
    const ids = try f.buildStandard();
    const gpa = testing.allocator;
    var path = try f.tree.dispatchPath(gpa, ids.editor);
    defer path.deinit(gpa);

    // First stroke is a prefix (and itself bound): pending with binding.
    var r1 = try f.tree.dispatchKey(gpa, &.{}, f.key("cmd-k"), path.items);
    defer r1.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r1.pending.items.len);
    try testing.expect(r1.pending_has_binding);
    try testing.expectEqual(@as(usize, 0), r1.bindings.items.len);

    // Second stroke completes the chord.
    var r2 = try f.tree.dispatchKey(gpa, r1.pending.items, f.key("cmd-s"), path.items);
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r2.pending.items.len);
    try testing.expect(r2.bindings.items[0].action.is(SaveAll));
    try testing.expectEqual(@as(usize, 0), r2.to_replay.items.len);

    // A non-matching second stroke replays cmd-k (→ Find) then handles `x` normally.
    var r3 = try f.tree.dispatchKey(gpa, r1.pending.items, f.key("x"), path.items);
    defer r3.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r3.to_replay.items.len);
    try testing.expectEqualStrings("k", r3.to_replay.items[0].keystroke.key);
    try testing.expect(r3.to_replay.items[0].bindings.items[0].action.is(Find));
    try testing.expect(r3.bindings.items[0].action.is(Close));

    // From the terminal, cmd-k alone is unbound: replay has no bindings (goes to text input).
    var tpath = try f.tree.dispatchPath(gpa, ids.terminal);
    defer tpath.deinit(gpa);
    var r4 = try f.tree.dispatchKey(gpa, &.{}, f.key("cmd-k"), tpath.items);
    defer r4.deinit(gpa);
    try testing.expect(!r4.pending_has_binding);
    var r5 = try f.tree.dispatchKey(gpa, r4.pending.items, f.key("q"), tpath.items);
    defer r5.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r5.to_replay.items.len);
    try testing.expectEqual(@as(usize, 0), r5.to_replay.items[0].bindings.items.len);
    try testing.expectEqual(@as(usize, 0), r5.bindings.items.len);
}

test "flushDispatch converts pending input into replays" {
    const f = try Fixture.create(&.{
        .init("a b c", SaveAll{}, null),
        .init("a", Find{}, null),
    });
    defer f.destroy();
    _ = try f.buildStandard();
    const gpa = testing.allocator;
    var path = try f.tree.dispatchPath(gpa, .of(2));
    defer path.deinit(gpa);
    const pending = [_]Keystroke{ f.key("a"), f.key("b") };
    var replays = try f.tree.flushDispatch(gpa, &pending, path.items);
    defer deinitReplays(gpa, &replays);
    try testing.expectEqual(@as(usize, 2), replays.items.len);
    try testing.expect(replays.items[0].bindings.items[0].action.is(Find));
    try testing.expectEqualStrings("b", replays.items[1].keystroke.key);
    try testing.expectEqual(@as(usize, 0), replays.items[1].bindings.items.len);
}

test "PendingInput times out after 1s on the test clock" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try app.bindKeys(&.{
        .init("cmd-k", Find{}, null),
        .init("cmd-k cmd-s", SaveAll{}, null),
    });
    var tree = DispatchTree.init(testing.allocator, &app.keymap);
    defer tree.deinit();
    const root = try tree.pushNode();
    tree.popNode();
    const gpa = testing.allocator;
    var path = try tree.dispatchPath(gpa, root);
    defer path.deinit(gpa);

    // Simulates the window: keep pending input, arm a timer, flush on expiry.
    const Window = struct {
        const Self = @This();
        tree: *DispatchTree,
        path: []const DispatchNodeId,
        pending: PendingInput = .{},
        dispatched: std.ArrayList([]const u8) = .empty,

        const Flush = struct {
            w: *Self,
            pub fn finish(self: *Flush) void {
                const w = self.w;
                var replays = w.tree.flushDispatch(testing.allocator, w.pending.keystrokes.items, w.path) catch unreachable;
                defer deinitReplays(testing.allocator, &replays);
                for (replays.items) |r| for (r.bindings.items[0..@min(1, r.bindings.items.len)]) |b| {
                    w.dispatched.append(testing.allocator, b.action.name) catch unreachable;
                };
                w.pending.timer.detach();
                w.pending.clear(testing.allocator);
            }
        };

        fn keyDown(w: *Self, a: *App, k: Keystroke) !void {
            var r = try w.tree.dispatchKey(testing.allocator, w.pending.keystrokes.items, k, w.path);
            defer r.deinit(testing.allocator);
            if (r.pending.items.len > 0) {
                w.pending.timer.cancel();
                try w.pending.set(testing.allocator, r.pending.items);
                w.pending.needs_timeout = w.pending.needs_timeout or r.pending_has_binding;
                if (w.pending.needs_timeout)
                    w.pending.timer = try a.foregroundExecutor().timer(PendingInput.timeout_ns, Flush{ .w = w });
                return;
            }
            w.pending.clear(testing.allocator);
            if (r.bindings.items.len > 0) try w.dispatched.append(testing.allocator, r.bindings.items[0].action.name);
        }
    };
    var w: Window = .{ .tree = &tree, .path = path.items };
    defer w.dispatched.deinit(gpa);
    defer w.pending.deinit(gpa);

    const k = try keymap_mod.parseKeystroke(gpa, "cmd-k");
    defer keymap_mod.freeKeystroke(gpa, k);
    try w.keyDown(app, k);
    app.advanceClock(999 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 0), w.dispatched.items.len);
    try testing.expect(!w.pending.isEmpty());
    app.advanceClock(std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), w.dispatched.items.len);
    try testing.expectEqualStrings("test::Find", w.dispatched.items[0]);
    try testing.expect(w.pending.isEmpty());

    // Completing the chord before the timeout cancels the timer.
    try w.keyDown(app, k);
    const s = try keymap_mod.parseKeystroke(gpa, "cmd-s");
    defer keymap_mod.freeKeystroke(gpa, s);
    app.advanceClock(500 * std.time.ns_per_ms);
    try w.keyDown(app, s);
    app.advanceClock(2 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 2), w.dispatched.items.len);
    try testing.expectEqualStrings("test::SaveAll", w.dispatched.items[1]);
}

test "bindingsForAction respects shadowing in the current context" {
    const f = try Fixture.create(&.{
        .init("cmd-s", Save{}, "Workspace"),
        .init("cmd-shift-s", Save{}, null),
        .init("cmd-s", SaveAll{}, "Editor"),
    });
    defer f.destroy();
    const ids = try f.buildStandard();
    const gpa = testing.allocator;
    var path = try f.tree.dispatchPath(gpa, ids.editor);
    defer path.deinit(gpa);
    var ctxs = try f.tree.contextStackFor(gpa, path.items);
    defer ctxs.deinit(gpa);
    var save = try AnyAction.init(gpa, Save{});
    defer save.deinit(gpa);

    var list = try f.tree.bindingsForAction(gpa, save, ctxs.items);
    defer list.deinit(gpa);
    // cmd-s is shadowed by SaveAll in the editor; cmd-shift-s remains.
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("s", list.items[0].keystrokes[0].key);
    try testing.expect(list.items[0].keystrokes[0].modifiers.shift);
    const best = (try f.tree.highestPrecedenceBindingForAction(gpa, save, ctxs.items)).?;
    try testing.expect(best == list.items[0]);

    // At workspace level both bindings are live.
    var wpath = try f.tree.dispatchPath(gpa, ids.workspace);
    defer wpath.deinit(gpa);
    var wctxs = try f.tree.contextStackFor(gpa, wpath.items);
    defer wctxs.deinit(gpa);
    var wlist = try f.tree.bindingsForAction(gpa, save, wctxs.items);
    defer wlist.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), wlist.items.len);
}

test "reuseSubtree moves nodes and listeners from the previous frame" {
    const f = try Fixture.create(&.{});
    defer f.destroy();
    _ = try f.buildStandard();
    try f.tree.setActiveNode(.of(2));
    try f.tree.onAction(.{ .action_type = type_id.typeId(Save), .func = noopAction });
    while (f.tree.activeNodeId() != null) f.tree.popNode();

    var next = DispatchTree.init(testing.allocator, &f.keymap);
    defer next.deinit();
    _ = try next.pushNode();
    try next.setKeyContext(f.ctx("Root"));
    // Reuse the Pane subtree (nodes 1..4: Pane, Editor, Terminal).
    const reused = try next.reuseSubtree(1, 3, &f.tree, @fromBackingInt(@intCast(3)));
    next.popNode();
    try testing.expect(reused.contains_focus);
    try testing.expectEqual(@as(usize, 4), next.len());
    const editor = reused.refreshNodeId(.of(2));
    try testing.expectEqual(@as(usize, 2), editor.index());
    try testing.expect(next.isActionAvailable(type_id.typeId(Save), editor));
    try testing.expectEqual(@as(usize, 0), f.tree.nodes.items[2].action_listeners.items.len);
    try testing.expect(next.focusContains(@fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(4))));
    var path = try next.dispatchPath(testing.allocator, editor);
    defer path.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), path.items.len);

    next.truncate(2);
    try testing.expectEqual(@as(usize, 2), next.len());
    try testing.expect(next.focusableNodeId(@fromBackingInt(@intCast(3))) == null);
}
