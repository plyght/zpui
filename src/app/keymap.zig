//! Keystroke parsing, key bindings and the keymap (gpui `keymap.rs`, `keymap/binding.rs`,
//! `platform/keystroke.rs`).
//!
//! ```zig
//! try app.bindKeys(&.{
//!     .init("cmd-z", Undo{}, "Editor"),
//!     .init("cmd-k cmd-s", OpenKeymap{}, null),          // multi-stroke
//!     .init("ctrl-shift-tab", PrevTab{}, "Pane && !Terminal"),
//! });
//! ```
//!
//! Precedence (gpui): bindings matching deeper in the context stack win; at equal depth,
//! bindings added later win. Context-less bindings count as matching at the deepest level.
//! `NoAction` disables shadowed bindings; `Unbind{ .target = "ns::Action" }` removes
//! lower-precedence bindings of the same keystrokes for that action.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const action_mod = @import("action.zig");
const AnyAction = action_mod.AnyAction;
const key_context = @import("key_context.zig");
const KeyContext = key_context.KeyContext;
const Predicate = key_context.Predicate;
const type_id = @import("type_id.zig");

pub const Keystroke = input.Keystroke;
pub const Modifiers = input.Modifiers;

pub const ParseKeystrokeError = Allocator.Error || error{InvalidKeystroke};

/// Parse `[secondary-][ctrl-][alt-][shift-][cmd-|super-|win-][fn-]key[->key_char]`.
/// `"A"` means shift-a; `"ctrl--"` is ctrl + minus; a lone modifier becomes the key.
/// The returned key strings are allocated with `gpa` (free with `freeKeystroke`).
pub fn parseKeystroke(gpa: Allocator, source: []const u8) ParseKeystrokeError!Keystroke {
    var mods: Modifiers = .{};
    var key: ?[]const u8 = null;
    var key_char: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, source, '-');
    while (it.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, "ctrl")) {
            mods.control = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "alt")) {
            mods.alt = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "shift")) {
            mods.shift = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "fn")) {
            mods.function = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "secondary")) {
            if (builtin.os.tag == .macos) mods.platform = true else mods.control = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(component, "cmd") or std.ascii.eqlIgnoreCase(component, "super") or
            std.ascii.eqlIgnoreCase(component, "win"))
        {
            mods.platform = true;
            continue;
        }

        if (it.peek()) |next| {
            if (next.len == 0 and std.mem.endsWith(u8, source, "-")) {
                key = "-";
                break;
            } else if (next.len > 1 and next[0] == '>') {
                key = component;
                key_char = next[1..];
                _ = it.next();
            } else {
                return error.InvalidKeystroke;
            }
            continue;
        }
        if (component.len == 1 and std.ascii.isUpper(component[0])) {
            mods.shift = true;
        }
        key = component;
    }

    if (key == null) {
        if (mods.shift) {
            mods.shift = false;
            key = "shift";
        } else if (mods.control) {
            mods.control = false;
            key = "control";
        } else if (mods.alt) {
            mods.alt = false;
            key = "alt";
        } else if (mods.platform) {
            mods.platform = false;
            key = "platform";
        } else if (mods.function) {
            mods.function = false;
            key = "function";
        } else return error.InvalidKeystroke;
    }

    if (key.?.len == 0) return error.InvalidKeystroke;
    const owned_key = try std.ascii.allocLowerString(gpa, key.?);
    errdefer gpa.free(owned_key);
    const owned_char: ?[]const u8 = if (key_char) |kc| try gpa.dupe(u8, kc) else null;
    return .{ .modifiers = mods, .key = owned_key, .key_char = owned_char };
}

pub fn freeKeystroke(gpa: Allocator, ks: Keystroke) void {
    gpa.free(ks.key);
    if (ks.key_char) |kc| gpa.free(kc);
}

pub fn dupeKeystroke(gpa: Allocator, ks: Keystroke) Allocator.Error!Keystroke {
    const key = try gpa.dupe(u8, ks.key);
    errdefer gpa.free(key);
    const kc: ?[]const u8 = if (ks.key_char) |c| try gpa.dupe(u8, c) else null;
    return .{ .modifiers = ks.modifiers, .key = key, .key_char = kc };
}

/// `{f}`-formattable keystroke: `std.debug.print("{f}", .{fmtKeystroke(ks)})`.
pub fn fmtKeystroke(ks: Keystroke) KeystrokeFormatter {
    return .{ .ks = ks };
}

pub const KeystrokeFormatter = struct {
    ks: Keystroke,
    pub fn format(self: KeystrokeFormatter, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return formatKeystroke(self.ks, w);
    }
};

/// Inverse of `parseKeystroke` (without key_char), gpui modifier order.
pub fn formatKeystroke(ks: Keystroke, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const m = ks.modifiers;
    if (m.function) try w.writeAll("fn-");
    if (m.control) try w.writeAll("ctrl-");
    if (m.alt) try w.writeAll("alt-");
    if (m.platform) try w.writeAll(switch (builtin.os.tag) {
        .macos => "cmd-",
        .windows => "win-",
        else => "super-",
    });
    if (m.shift) try w.writeAll("shift-");
    try w.writeAll(ks.key);
}

pub fn keystrokeEql(a: Keystroke, b: Keystroke) bool {
    return a.modifiers.eql(b.modifiers) and std.mem.eql(u8, a.key, b.key);
}

/// Whether `typed` (from the platform) triggers binding keystroke `target`. A typed key that
/// produced a different `key_char` (e.g. alt-s → "ß") also matches a binding for that char.
pub fn shouldMatch(typed: Keystroke, target: Keystroke) bool {
    if (typed.key_char) |kc| {
        if (!std.mem.eql(u8, kc, typed.key)) {
            const ime_mods: Modifiers = if (builtin.os.tag == .windows)
                .{}
            else
                .{ .control = typed.modifiers.control, .platform = typed.modifiers.platform };
            if (std.mem.eql(u8, target.key, kc) and target.modifiers.eql(ime_mods)) return true;
        }
    }
    return keystrokeEql(typed, target);
}

pub const BindingError = ParseKeystrokeError || key_context.ParseError;

/// A keystroke sequence bound to an action, optionally under a context predicate.
pub const KeyBinding = struct {
    keystrokes: []const Keystroke,
    action: AnyAction,
    predicate: ?*const Predicate = null,
    /// Source text of the predicate (owned).
    context: ?[]const u8 = null,
    /// User-defined metadata index (gpui `KeyBindingMetaIndex`, e.g. keymap source).
    meta: ?u32 = null,
    arena: std.heap.ArenaAllocator.State = .init,

    /// Parse `keystrokes` ("cmd-k cmd-s") and `context`. Takes ownership of `action`
    /// (freed on error too).
    pub fn init(gpa: Allocator, keystrokes: []const u8, action: AnyAction, context: ?[]const u8) BindingError!KeyBinding {
        var act = action;
        errdefer act.deinit(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var list: std.ArrayList(Keystroke) = .empty;
        var it = std.mem.tokenizeAny(u8, keystrokes, " \t\r\n");
        while (it.next()) |src| try list.append(a, try parseKeystroke(a, src));
        if (list.items.len == 0) return error.InvalidKeystroke;

        var pred: ?*const Predicate = null;
        var ctx_src: ?[]const u8 = null;
        if (context) |c| {
            const owned = try a.dupe(u8, c);
            ctx_src = owned;
            pred = try Predicate.parse(a, owned);
        }
        return .{
            .keystrokes = list.items,
            .action = act,
            .predicate = pred,
            .context = ctx_src,
            .arena = arena.state,
        };
    }

    pub fn deinit(self: *KeyBinding, gpa: Allocator) void {
        self.action.deinit(gpa);
        self.arena.promote(gpa).deinit();
        self.* = undefined;
    }

    /// null: no match; false: complete match; true: `typed` is a strict prefix (pending).
    pub fn matchKeystrokes(self: *const KeyBinding, typed: []const Keystroke) ?bool {
        if (self.keystrokes.len < typed.len) return null;
        for (self.keystrokes[0..typed.len], typed) |target, t| {
            if (!shouldMatch(t, target)) return null;
        }
        return self.keystrokes.len > typed.len;
    }

    pub fn sameKeystrokes(a: *const KeyBinding, b: *const KeyBinding) bool {
        if (a.keystrokes.len != b.keystrokes.len) return false;
        for (a.keystrokes, b.keystrokes) |x, y| if (!keystrokeEql(x, y)) return false;
        return true;
    }
};

/// Comptime-friendly binding description for `App.bindKeys` / `Keymap.addSpecs`.
pub const BindingSpec = struct {
    keystrokes: []const u8,
    context: ?[]const u8,
    make_action: *const fn (gpa: Allocator) Allocator.Error!AnyAction,
    meta: ?u32 = null,

    pub fn init(comptime keystrokes: []const u8, comptime act: anytype, comptime context: ?[]const u8) BindingSpec {
        return .{
            .keystrokes = keystrokes,
            .context = context,
            .make_action = struct {
                fn make(gpa: Allocator) Allocator.Error!AnyAction {
                    return AnyAction.init(gpa, act);
                }
            }.make,
        };
    }

    pub fn withMeta(self: BindingSpec, meta: u32) BindingSpec {
        var s = self;
        s.meta = meta;
        return s;
    }
};

pub const Keymap = struct {
    gpa: Allocator,
    bindings: std.ArrayList(KeyBinding) = .empty,
    by_action: std.AutoHashMapUnmanaged(u64, std.ArrayList(usize)) = .empty,
    disabled: std.ArrayList(usize) = .empty,
    /// Bumped whenever bindings change.
    version: usize = 0,

    pub fn init(gpa: Allocator) Keymap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Keymap) void {
        self.clear();
        self.bindings.deinit(self.gpa);
        self.by_action.deinit(self.gpa);
        self.disabled.deinit(self.gpa);
    }

    pub fn clear(self: *Keymap) void {
        for (self.bindings.items) |*b| b.deinit(self.gpa);
        self.bindings.clearRetainingCapacity();
        var it = self.by_action.valueIterator();
        while (it.next()) |l| l.deinit(self.gpa);
        self.by_action.clearRetainingCapacity();
        self.disabled.clearRetainingCapacity();
        self.version += 1;
    }

    /// Add a binding (ownership moves to the keymap, also on error).
    pub fn add(self: *Keymap, binding: KeyBinding) Allocator.Error!void {
        var b = binding;
        errdefer b.deinit(self.gpa);
        const ix = self.bindings.items.len;
        try self.bindings.ensureUnusedCapacity(self.gpa, 1);
        if (b.action.isNoAction() or b.action.isUnbind()) {
            try self.disabled.append(self.gpa, ix);
        } else {
            const gop = try self.by_action.getOrPut(self.gpa, type_id.key(b.action.type_id));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, ix);
        }
        self.bindings.appendAssumeCapacity(b);
        self.version += 1;
    }

    pub fn addSpecs(self: *Keymap, specs: []const BindingSpec) BindingError!void {
        for (specs) |s| {
            const act = try s.make_action(self.gpa);
            var b = try KeyBinding.init(self.gpa, s.keystrokes, act, s.context);
            b.meta = s.meta;
            try self.add(b);
        }
    }

    /// Depth in `contexts` at which `binding` is enabled, or null.
    pub fn bindingEnabled(binding: *const KeyBinding, contexts: []const KeyContext) ?usize {
        if (binding.predicate) |p| return p.depthOf(contexts);
        return contexts.len;
    }

    pub const Match = struct {
        /// Highest precedence first. Pointers are valid until the keymap changes.
        bindings: std.ArrayList(*const KeyBinding) = .empty,
        /// Longer input could still match some binding.
        pending: bool = false,

        pub fn deinit(self: *Match, gpa: Allocator) void {
            self.bindings.deinit(gpa);
        }
    };

    const Ranked = struct { depth: usize, ix: usize };

    fn binding_is_unbound(disabled: *const KeyBinding, binding: *const KeyBinding) bool {
        if (!disabled.sameKeystrokes(binding)) return false;
        const u = disabled.action.downcast(action_mod.Unbind) orelse return false;
        return std.mem.eql(u8, u.target, binding.action.name);
    }

    /// gpui `bindings_for_input`: bindings matching `input` under `contexts` (root → leaf),
    /// and whether more input could match.
    pub fn bindingsForInput(self: *const Keymap, gpa: Allocator, typed: []const Keystroke, contexts: []const KeyContext) Allocator.Error!Match {
        var matched: std.ArrayList(Ranked) = .empty;
        defer matched.deinit(gpa);
        var pending_ix: std.ArrayList(usize) = .empty;
        defer pending_ix.deinit(gpa);

        var ix = self.bindings.items.len;
        while (ix > 0) {
            ix -= 1;
            const b = &self.bindings.items[ix];
            const depth = bindingEnabled(b, contexts) orelse continue;
            const is_pending = b.matchKeystrokes(typed) orelse continue;
            if (is_pending) try pending_ix.append(gpa, ix) else try matched.append(gpa, .{ .depth = depth, .ix = ix });
        }

        std.mem.sort(Ranked, matched.items, {}, struct {
            fn lessThan(_: void, a: Ranked, b: Ranked) bool {
                if (a.depth != b.depth) return a.depth > b.depth;
                return a.ix > b.ix;
            }
        }.lessThan);

        var result: Match = .{};
        errdefer result.deinit(gpa);
        var first_binding_ix: ?usize = null;
        var unbinds: std.ArrayList(*const KeyBinding) = .empty;
        defer unbinds.deinit(gpa);

        for (matched.items) |r| {
            const b = &self.bindings.items[r.ix];
            if (b.action.isNoAction()) {
                // Only a user NoAction (meta 0 or unset) stops the search.
                if (b.meta) |m| {
                    if (m == 0) break;
                    continue;
                }
                break;
            }
            if (b.action.isUnbind()) {
                try unbinds.append(gpa, b);
                continue;
            }
            var shadowed = false;
            for (unbinds.items) |u| if (binding_is_unbound(u, b)) {
                shadowed = true;
                break;
            };
            if (shadowed) continue;
            try result.bindings.append(gpa, b);
            if (first_binding_ix == null) first_binding_ix = r.ix;
        }

        // Pending: walk in insertion order so later NoAction/Unbind cancel earlier prefixes.
        var pending_set: std.ArrayList(*const KeyBinding) = .empty;
        defer pending_set.deinit(gpa);
        var i = pending_ix.items.len;
        while (i > 0) {
            i -= 1;
            const pix = pending_ix.items[i];
            if (first_binding_ix) |fix| if (fix > pix) continue;
            const b = &self.bindings.items[pix];
            if (b.action.isNoAction() or b.action.isUnbind()) {
                var j: usize = 0;
                while (j < pending_set.items.len) {
                    if (pending_set.items[j].sameKeystrokes(b)) _ = pending_set.swapRemove(j) else j += 1;
                }
                continue;
            }
            var dup = false;
            for (pending_set.items) |p| if (p.sameKeystrokes(b)) {
                dup = true;
                break;
            };
            if (!dup) try pending_set.append(gpa, b);
        }
        result.pending = pending_set.items.len != 0;
        return result;
    }

    fn disabledMatchesContext(disabled: *const KeyBinding, binding: *const KeyBinding) bool {
        const dp = disabled.predicate orelse return true;
        const bp = binding.predicate orelse return false;
        return dp.isSuperset(bp);
    }

    /// Bindings for `action` in insertion order (last = highest precedence for display),
    /// excluding ones disabled by later NoAction/Unbind bindings.
    pub fn bindingsForAction(self: *const Keymap, gpa: Allocator, action: AnyAction) Allocator.Error!std.ArrayList(*const KeyBinding) {
        var out: std.ArrayList(*const KeyBinding) = .empty;
        errdefer out.deinit(gpa);
        const indices = self.by_action.get(type_id.key(action.type_id)) orelse return out;
        outer: for (indices.items) |ix| {
            const b = &self.bindings.items[ix];
            if (!b.action.eql(action)) continue;
            for (self.disabled.items) |dix| {
                if (dix <= ix) continue;
                const d = &self.bindings.items[dix];
                if (!d.sameKeystrokes(b)) continue;
                if (d.action.isNoAction()) {
                    if (disabledMatchesContext(d, b)) continue :outer;
                } else if (d.action.isUnbind() and disabledMatchesContext(d, b) and binding_is_unbound(d, b)) {
                    continue :outer;
                }
            }
            try out.append(gpa, b);
        }
        return out;
    }

    /// Bindings that could follow `typed` (pending matches), highest precedence first.
    pub fn possibleNextBindings(self: *const Keymap, gpa: Allocator, typed: []const Keystroke, contexts: []const KeyContext) Allocator.Error!std.ArrayList(*const KeyBinding) {
        var ranked: std.ArrayList(Ranked) = .empty;
        defer ranked.deinit(gpa);
        for (self.bindings.items, 0..) |*b, ix| {
            const depth = bindingEnabled(b, contexts) orelse continue;
            const is_pending = b.matchKeystrokes(typed) orelse continue;
            if (!is_pending or b.action.isNoAction() or b.action.isUnbind()) continue;
            try ranked.append(gpa, .{ .depth = depth, .ix = ix });
        }
        std.mem.sort(Ranked, ranked.items, {}, struct {
            fn lessThan(_: void, a: Ranked, b: Ranked) bool {
                if (a.depth != b.depth) return a.depth > b.depth;
                return a.ix > b.ix;
            }
        }.lessThan);
        var out: std.ArrayList(*const KeyBinding) = .empty;
        errdefer out.deinit(gpa);
        for (ranked.items) |r| try out.append(gpa, &self.bindings.items[r.ix]);
        return out;
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;
const NoAction = action_mod.NoAction;
const Unbind = action_mod.Unbind;
const ActionAlpha = action_mod.action("test_only::ActionAlpha");
const ActionBeta = action_mod.action("test_only::ActionBeta");
const ActionGamma = action_mod.action("test_only::ActionGamma");

test "parseKeystroke" {
    const gpa = testing.allocator;
    {
        const k = try parseKeystroke(gpa, "cmd-k");
        defer freeKeystroke(gpa, k);
        try testing.expect(k.modifiers.platform and !k.modifiers.control);
        try testing.expectEqualStrings("k", k.key);
    }
    {
        const k = try parseKeystroke(gpa, "ctrl-shift-tab");
        defer freeKeystroke(gpa, k);
        try testing.expect(k.modifiers.control and k.modifiers.shift);
        try testing.expectEqualStrings("tab", k.key);
    }
    {
        const k = try parseKeystroke(gpa, "A");
        defer freeKeystroke(gpa, k);
        try testing.expect(k.modifiers.shift);
        try testing.expectEqualStrings("a", k.key);
    }
    {
        const k = try parseKeystroke(gpa, "ctrl--");
        defer freeKeystroke(gpa, k);
        try testing.expect(k.modifiers.control);
        try testing.expectEqualStrings("-", k.key);
    }
    {
        const k = try parseKeystroke(gpa, "Enter");
        defer freeKeystroke(gpa, k);
        try testing.expectEqualStrings("enter", k.key);
        try testing.expect(k.modifiers.none());
    }
    {
        const k = try parseKeystroke(gpa, "shift");
        defer freeKeystroke(gpa, k);
        try testing.expectEqualStrings("shift", k.key);
        try testing.expect(k.modifiers.none());
    }
    {
        const k = try parseKeystroke(gpa, "alt-s->ß");
        defer freeKeystroke(gpa, k);
        try testing.expect(k.modifiers.alt);
        try testing.expectEqualStrings("s", k.key);
        try testing.expectEqualStrings("ß", k.key_char.?);
    }
    {
        const k = try parseKeystroke(gpa, "secondary-s");
        defer freeKeystroke(gpa, k);
        try testing.expect(k.modifiers.secondary());
    }
    try testing.expectError(error.InvalidKeystroke, parseKeystroke(gpa, "ctrl-a-b"));
    try testing.expectError(error.InvalidKeystroke, parseKeystroke(gpa, ""));

    const k = try parseKeystroke(gpa, "alt-ctrl-shift-x");
    defer freeKeystroke(gpa, k);
    try testing.expectFmt("ctrl-alt-shift-x", "{f}", .{fmtKeystroke(k)});
}

test "shouldMatch with key_char" {
    // Typed alt-s producing "ß" matches a binding for "ß" (non-Windows) and for alt-s.
    const typed: Keystroke = .{ .modifiers = .{ .alt = true }, .key = "s", .key_char = "ß" };
    const target_char: Keystroke = .{ .key = "ß" };
    const target_key: Keystroke = .{ .modifiers = .{ .alt = true }, .key = "s" };
    try testing.expectEqual(builtin.os.tag != .windows, shouldMatch(typed, target_char));
    try testing.expect(shouldMatch(typed, target_key));
    try testing.expect(!shouldMatch(.{ .key = "a" }, .{ .key = "b" }));
    try testing.expect(!shouldMatch(.{ .key = "a" }, .{ .modifiers = .{ .control = true }, .key = "a" }));
}

const TestKeymap = struct {
    arena: std.heap.ArenaAllocator,
    keymap: Keymap,

    fn init(specs: []const BindingSpec) TestKeymap {
        var t: TestKeymap = .{ .arena = .init(testing.allocator), .keymap = .init(testing.allocator) };
        t.keymap.addSpecs(specs) catch unreachable;
        return t;
    }
    fn deinit(t: *TestKeymap) void {
        t.keymap.deinit();
        t.arena.deinit();
    }
    fn contexts(t: *TestKeymap, srcs: []const []const u8) []const KeyContext {
        const a = t.arena.allocator();
        const out = a.alloc(KeyContext, srcs.len) catch unreachable;
        for (srcs, out) |s, *c| c.* = KeyContext.parse(a, s) catch unreachable;
        return out;
    }
    fn input(t: *TestKeymap, src: []const u8) []const Keystroke {
        const a = t.arena.allocator();
        var list: std.ArrayList(Keystroke) = .empty;
        var it = std.mem.tokenizeScalar(u8, src, ' ');
        while (it.next()) |s| list.append(a, parseKeystroke(a, s) catch unreachable) catch unreachable;
        return list.items;
    }
    fn match(t: *TestKeymap, keys: []const u8, ctxs: []const []const u8) Keymap.Match {
        return t.keymap.bindingsForInput(t.arena.allocator(), t.input(keys), t.contexts(ctxs)) catch unreachable;
    }
};

test "Keymap: binding enabled depth" {
    var t = TestKeymap.init(&.{
        .init("ctrl-a", ActionAlpha{}, null),
        .init("ctrl-a", ActionBeta{}, "pane"),
        .init("ctrl-a", ActionGamma{}, "editor && mode==full"),
    });
    defer t.deinit();
    const b = t.keymap.bindings.items;
    try testing.expectEqual(@as(?usize, 0), Keymap.bindingEnabled(&b[0], &.{}));
    try testing.expectEqual(@as(?usize, 1), Keymap.bindingEnabled(&b[0], t.contexts(&.{"terminal"})));
    try testing.expectEqual(@as(?usize, null), Keymap.bindingEnabled(&b[1], t.contexts(&.{"barf x=y"})));
    try testing.expectEqual(@as(?usize, 1), Keymap.bindingEnabled(&b[1], t.contexts(&.{"pane x=y"})));
    try testing.expectEqual(@as(?usize, null), Keymap.bindingEnabled(&b[2], t.contexts(&.{"editor"})));
    try testing.expectEqual(@as(?usize, 1), Keymap.bindingEnabled(&b[2], t.contexts(&.{"editor mode=full"})));
}

test "Keymap: depth precedence and later-wins" {
    var t = TestKeymap.init(&.{
        .init("ctrl-a", ActionBeta{}, "pane"),
        .init("ctrl-a", ActionGamma{}, "editor"),
    });
    defer t.deinit();
    const m = t.match("ctrl-a", &.{ "pane", "editor" });
    try testing.expect(!m.pending);
    try testing.expectEqual(@as(usize, 2), m.bindings.items.len);
    try testing.expect(m.bindings.items[0].action.is(ActionGamma));
    try testing.expect(m.bindings.items[1].action.is(ActionBeta));

    var t2 = TestKeymap.init(&.{
        .init("cmd-r", ActionAlpha{}, "Editor"),
        .init("cmd-r", ActionBeta{}, "Editor"),
    });
    defer t2.deinit();
    const m2 = t2.match("cmd-r", &.{"Editor"});
    try testing.expect(m2.bindings.items[0].action.is(ActionBeta));
}

test "Keymap: NoAction disables bindings" {
    var t = TestKeymap.init(&.{
        .init("ctrl-a", ActionAlpha{}, "editor"),
        .init("ctrl-b", ActionAlpha{}, "editor"),
        .init("ctrl-a", NoAction{}, "editor && mode==full"),
        .init("ctrl-b", NoAction{}, null),
    });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.match("ctrl-a", &.{"barf"}).bindings.items.len);
    try testing.expectEqual(@as(usize, 1), t.match("ctrl-a", &.{"editor"}).bindings.items.len);
    try testing.expectEqual(@as(usize, 0), t.match("ctrl-a", &.{"editor mode=full"}).bindings.items.len);
    try testing.expectEqual(@as(usize, 0), t.match("ctrl-b", &.{"barf"}).bindings.items.len);

    var t2 = TestKeymap.init(&.{
        .init("ctrl-x", ActionAlpha{}, "editor"),
        .init("ctrl-x", NoAction{}, "workspace"),
    });
    defer t2.deinit();
    // Disabled at the wrong (shallower) level: still bound.
    try testing.expectEqual(@as(usize, 1), t2.match("ctrl-x", &.{ "workspace", "editor" }).bindings.items.len);

    var t3 = TestKeymap.init(&.{
        .init("ctrl-x", ActionAlpha{}, "workspace"),
        .init("ctrl-x", NoAction{}, "editor"),
    });
    defer t3.deinit();
    const m3 = t3.match("ctrl-x", &.{ "workspace", "editor" });
    try testing.expectEqual(@as(usize, 0), m3.bindings.items.len);
    try testing.expect(!m3.pending);
}

test "Keymap: multi-stroke pending and NoAction (zed#30259)" {
    var t = TestKeymap.init(&.{
        .init("space w w", ActionAlpha{}, "workspace"),
        .init("space w w", NoAction{}, "editor"),
    });
    defer t.deinit();
    const ws: []const []const u8 = &.{"workspace"};
    const ed: []const []const u8 = &.{ "workspace", "editor" };
    var m = t.match("space", ws);
    try testing.expect(m.bindings.items.len == 0 and m.pending);
    m = t.match("space", ed);
    try testing.expect(m.bindings.items.len == 0 and !m.pending);
    m = t.match("space w", ws);
    try testing.expect(m.bindings.items.len == 0 and m.pending);
    m = t.match("space w", ed);
    try testing.expect(m.bindings.items.len == 0 and !m.pending);
    m = t.match("space w w", ws);
    try testing.expect(m.bindings.items.len == 1 and !m.pending);
    m = t.match("space w w", ed);
    try testing.expect(m.bindings.items.len == 0 and !m.pending);

    var t2 = TestKeymap.init(&.{
        .init("space w w", ActionAlpha{}, "workspace"),
        .init("space w w", NoAction{}, "editor"),
        .init("space w x", ActionAlpha{}, "editor"),
    });
    defer t2.deinit();
    try testing.expect(t2.match("space", ed).pending);

    var t3 = TestKeymap.init(&.{
        .init("space w w", ActionAlpha{}, "workspace"),
        .init("space w x", ActionAlpha{}, "editor"),
        .init("space w w", NoAction{}, "editor"),
    });
    defer t3.deinit();
    try testing.expect(t3.match("space", ed).pending);
}

test "Keymap: prefix override and pending-with-match" {
    var t = TestKeymap.init(&.{
        .init("ctrl-w left", ActionAlpha{}, "editor"),
        .init("ctrl-w", NoAction{}, "editor"),
    });
    defer t.deinit();
    var m = t.match("ctrl-w", &.{"editor"});
    try testing.expect(m.bindings.items.len == 0 and m.pending);

    var t2 = TestKeymap.init(&.{
        .init("ctrl-w left", ActionAlpha{}, "editor"),
        .init("ctrl-w", ActionBeta{}, "editor"),
    });
    defer t2.deinit();
    m = t2.match("ctrl-w", &.{"editor"});
    try testing.expect(m.bindings.items.len == 1 and !m.pending);

    var t3 = TestKeymap.init(&.{
        .init("ctrl-x", ActionBeta{}, "vim_mode == normal"),
        .init("ctrl-x 0", ActionAlpha{}, "Workspace"),
    });
    defer t3.deinit();
    m = t3.match("ctrl-x", &.{ "Workspace", "Pane", "Editor vim_mode=normal" });
    try testing.expect(m.bindings.items.len == 1 and m.bindings.items[0].action.is(ActionBeta));
    try testing.expect(m.pending);

    var t4 = TestKeymap.init(&.{
        .init("ctrl-x 0", ActionAlpha{}, "Workspace"),
        .init("ctrl-x", ActionBeta{}, "vim_mode == normal"),
    });
    defer t4.deinit();
    m = t4.match("ctrl-x", &.{ "Workspace", "Pane", "Editor vim_mode=normal" });
    try testing.expect(m.bindings.items.len == 1 and !m.pending);
}

test "Keymap: user NoAction vs base NoAction via meta" {
    var t = TestKeymap.init(&.{
        BindingSpec.init("cmd-r", ActionAlpha{}, "Editor").withMeta(3),
        BindingSpec.init("cmd-r", NoAction{}, "Editor").withMeta(2), // base keymap: keep looking
    });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.match("cmd-r", &.{"Editor"}).bindings.items.len);
    var t2 = TestKeymap.init(&.{
        BindingSpec.init("cmd-r", ActionAlpha{}, "Editor").withMeta(3),
        BindingSpec.init("cmd-r", NoAction{}, "Editor").withMeta(0), // user: stop
    });
    defer t2.deinit();
    try testing.expectEqual(@as(usize, 0), t2.match("cmd-r", &.{"Editor"}).bindings.items.len);
}

test "Keymap: Unbind targets one action" {
    var t = TestKeymap.init(&.{
        .init("tab", ActionAlpha{}, "Editor"),
        .init("tab", ActionBeta{}, "Editor && showing_completions"),
        .init("tab", Unbind{ .target = "test_only::ActionAlpha" }, "Editor && edit_prediction"),
    });
    defer t.deinit();
    const m = t.match("tab", &.{"Editor showing_completions edit_prediction"});
    try testing.expect(!m.pending);
    try testing.expectEqual(@as(usize, 1), m.bindings.items.len);
    try testing.expect(m.bindings.items[0].action.is(ActionBeta));
}

test "Keymap: bindingsForAction" {
    const gpa = testing.allocator;
    var t = TestKeymap.init(&.{
        .init("ctrl-a", ActionAlpha{}, "pane"),
        .init("ctrl-b", ActionBeta{}, "editor && mode == full"),
        .init("ctrl-c", ActionGamma{}, "workspace"),
        .init("ctrl-a", NoAction{}, "pane && active"),
        .init("ctrl-b", NoAction{}, "editor"),
    });
    defer t.deinit();
    inline for (.{ .{ ActionAlpha{}, 1 }, .{ ActionBeta{}, 0 }, .{ ActionGamma{}, 1 } }) |c| {
        var act = try AnyAction.init(gpa, c[0]);
        defer act.deinit(gpa);
        var list = try t.keymap.bindingsForAction(gpa, act);
        defer list.deinit(gpa);
        try testing.expectEqual(@as(usize, c[1]), list.items.len);
    }

    var t2 = TestKeymap.init(&.{
        .init("tab", ActionAlpha{}, "Editor && edit_prediction"),
        .init("tab", Unbind{ .target = "test_only::ActionAlpha" }, "Editor"),
    });
    defer t2.deinit();
    var act = try AnyAction.init(gpa, ActionAlpha{});
    defer act.deinit(gpa);
    var list = try t2.keymap.bindingsForAction(gpa, act);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "Keymap: possibleNextBindings and invalid specs" {
    const gpa = testing.allocator;
    var t = TestKeymap.init(&.{
        .init("cmd-k cmd-s", ActionAlpha{}, null),
        .init("cmd-k cmd-t", ActionBeta{}, "Editor"),
        .init("cmd-k", ActionGamma{}, "Terminal"),
    });
    defer t.deinit();
    var next = try t.keymap.possibleNextBindings(gpa, t.input("cmd-k"), t.contexts(&.{"Editor"}));
    defer next.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), next.items.len);
    try testing.expect(next.items[0].action.is(ActionBeta)); // later wins at equal depth

    var km = Keymap.init(gpa);
    defer km.deinit();
    try testing.expectError(error.InvalidKeystroke, km.addSpecs(&.{.init("ctrl-a-b", ActionAlpha{}, null)}));
    try testing.expectError(error.UnexpectedEnd, km.addSpecs(&.{.init("a", ActionAlpha{}, "Editor &&")}));
    try testing.expectEqual(@as(usize, 0), km.bindings.items.len);
}
