//! zeron's default key bindings — port of `shell::apply_keymap` (with
//! `composer::init` + `input_bindings` + `message_enter_bindings`,
//! `app_menus::bind_keys` and `browser::bind_keys`).
//!
//! `defaultBindings` is pure (platform passed in) so both platforms are
//! testable from one machine; `applyKeymap` clears the app keymap and
//! installs the list in Rust's order (later bindings win ties in gpui's
//! precedence, so order matters). Customizable shortcuts come from
//! `KeymapConfig` (stored platform-neutral, "mod" → cmd/ctrl); an
//! unparseable combo falls back to that shortcut's default, a cleared jump
//! slot binds nothing. Not ported: gpui-base's file-editor keymap that Rust
//! reinstalls after clearing (no editor component here yet).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const model = @import("zeron_model");
const actions = @import("actions.zig");

const settings = model.settings;
const KeymapConfig = settings.KeymapConfig;
const ShortcutId = settings.ShortcutId;
const ComposerSendBehavior = settings.ComposerSendBehavior;
const composer = actions.composer;
const shell = actions.shell;

pub const generic_composer_context = "Composer";
pub const message_composer_context = "MessageComposer";
pub const palette_search_context = "PaletteSearch";
pub const browser_context = "Browser";

pub const Binding = struct {
    keystrokes: []const u8,
    context: ?[]const u8,
    action: Act,

    pub const Act = union(enum) {
        unit: struct {
            name: []const u8,
            make: *const fn (Allocator) Allocator.Error!zpui.AnyAction,
        },
        jump: usize,

        pub fn name(a: Act) []const u8 {
            return switch (a) {
                .unit => |u| u.name,
                .jump => shell.JumpSession.action_name,
            };
        }

        pub fn build(a: Act, gpa: Allocator) Allocator.Error!zpui.AnyAction {
            return switch (a) {
                .unit => |u| u.make(gpa),
                .jump => |slot| zpui.AnyAction.init(gpa, shell.JumpSession{ .slot = slot }),
            };
        }
    };
};

fn act(comptime A: type) Binding.Act {
    return .{ .unit = .{
        .name = A.action_name,
        .make = struct {
            fn make(gpa: Allocator) Allocator.Error!zpui.AnyAction {
                return zpui.AnyAction.init(gpa, A{});
            }
        }.make,
    } };
}

const Builder = struct {
    arena: Allocator,
    mac: bool,
    list: std.ArrayList(Binding) = .empty,

    fn add(b: *Builder, keystrokes: []const u8, a: Binding.Act, context: ?[]const u8) !void {
        try b.list.append(b.arena, .{ .keystrokes = keystrokes, .context = context, .action = a });
    }

    fn fmt(b: *Builder, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(b.arena, f, args);
    }

    fn platform(b: *Builder, combo: []const u8) ![]const u8 {
        var buf: [128]u8 = undefined;
        return b.arena.dupe(u8, settings.platformComboOn(&buf, b.mac, combo));
    }

    /// `valid_or_default`: the platform spelling of `combo` if it parses as a
    /// keystroke, else of `fallback`.
    fn validOrDefault(b: *Builder, combo: []const u8, fallback: []const u8) ![]const u8 {
        const candidate = try b.platform(combo);
        if (parses(b.arena, candidate)) return candidate;
        std.log.scoped(.zeron_keymap).warn("unparseable shortcut combo \"{s}\"; using default", .{combo});
        return b.platform(fallback);
    }
};

/// A single keystroke that zpui's parser accepts (gpui `Keystroke::parse`).
fn parses(arena: Allocator, keystroke: []const u8) bool {
    if (keystroke.len == 0 or std.mem.findScalar(u8, keystroke, ' ') != null) return false;
    _ = zpui.core.parseKeystroke(arena, keystroke) catch return false;
    return true;
}

fn keystrokeEql(arena: Allocator, a: []const u8, b: []const u8) bool {
    // `Keystroke::parse(a).ok() == Keystroke::parse(b).ok()` (both failing
    // compares equal, as in Rust).
    const ka = if (a.len == 0) null else zpui.core.parseKeystroke(arena, a) catch null;
    const kb = if (b.len == 0) null else zpui.core.parseKeystroke(arena, b) catch null;
    if (ka == null or kb == null) return ka == null and kb == null;
    return zpui.core.keymap.keystrokeEql(ka.?, kb.?);
}

/// `composer::input_bindings(context)`.
fn inputBindings(b: *Builder, ctx: []const u8) !void {
    const c: ?[]const u8 = ctx;
    try b.add("tab", act(composer.MentionTab), c);
    try b.add("shift-tab", act(composer.OutdentList), c);
    try b.add("shift-enter", act(composer.Newline), c);
    try b.add("backspace", act(composer.Backspace), c);
    try b.add("shift-backspace", act(composer.Backspace), c);
    try b.add("delete", act(composer.Delete), c);
    try b.add("left", act(composer.Left), c);
    try b.add("right", act(composer.Right), c);
    try b.add("up", act(composer.Up), c);
    try b.add("down", act(composer.Down), c);
    try b.add("shift-left", act(composer.SelectLeft), c);
    try b.add("shift-right", act(composer.SelectRight), c);
    try b.add("shift-up", act(composer.SelectUp), c);
    try b.add("shift-down", act(composer.SelectDown), c);
    try b.add("home", act(composer.Home), c);
    try b.add("end", act(composer.End), c);
    try b.add("shift-home", act(composer.SelectHome), c);
    try b.add("shift-end", act(composer.SelectEnd), c);
    try b.add("cmd-left", act(composer.Home), c);
    try b.add("cmd-right", act(composer.End), c);
    try b.add("cmd-up", act(composer.DocStart), c);
    try b.add("cmd-down", act(composer.DocEnd), c);
    try b.add("shift-cmd-left", act(composer.SelectHome), c);
    try b.add("shift-cmd-right", act(composer.SelectEnd), c);
    try b.add("shift-cmd-up", act(composer.SelectDocStart), c);
    try b.add("shift-cmd-down", act(composer.SelectDocEnd), c);
    try b.add("cmd-backspace", act(composer.DeleteToLineStart), c);
    try b.add("cmd-delete", act(composer.DeleteToLineEnd), c);
    for ([_][]const u8{ "cmd", "ctrl" }) |prefix| {
        try b.add(try b.fmt("{s}-z", .{prefix}), act(composer.Undo), c);
        try b.add(try b.fmt("shift-{s}-z", .{prefix}), act(composer.Redo), c);
    }
    const word: []const u8 = if (b.mac) "alt" else "ctrl";
    try b.add(try b.fmt("{s}-backspace", .{word}), act(composer.DeleteWordLeft), c);
    try b.add(try b.fmt("{s}-delete", .{word}), act(composer.DeleteWordRight), c);
    try b.add(try b.fmt("{s}-left", .{word}), act(composer.WordLeft), c);
    try b.add(try b.fmt("{s}-right", .{word}), act(composer.WordRight), c);
    try b.add(try b.fmt("shift-{s}-left", .{word}), act(composer.SelectWordLeft), c);
    try b.add(try b.fmt("shift-{s}-right", .{word}), act(composer.SelectWordRight), c);
    for ([_][]const u8{ "cmd", "ctrl" }) |prefix| {
        try b.add(try b.fmt("{s}-a", .{prefix}), act(composer.SelectAll), c);
        try b.add(try b.fmt("{s}-c", .{prefix}), act(composer.Copy), c);
        try b.add(try b.fmt("{s}-x", .{prefix}), act(composer.Cut), c);
        try b.add(try b.fmt("{s}-v", .{prefix}), act(composer.Paste), c);
    }
}

/// `composer::init(cx, send_behavior)`: palette, generic, then message bindings.
fn composerBindings(b: *Builder, send_behavior: ComposerSendBehavior) !void {
    // Palette-search context: TEXT-EDITING keys only (bare arrows/enter
    // bubble to the palette frame).
    const p: ?[]const u8 = palette_search_context;
    try b.add("backspace", act(composer.Backspace), p);
    try b.add("shift-backspace", act(composer.Backspace), p);
    try b.add("delete", act(composer.Delete), p);
    try b.add("home", act(composer.Home), p);
    try b.add("end", act(composer.End), p);
    try b.add("shift-left", act(composer.SelectLeft), p);
    try b.add("shift-right", act(composer.SelectRight), p);
    try b.add("cmd-left", act(composer.Home), p);
    try b.add("cmd-right", act(composer.End), p);
    try b.add("shift-cmd-left", act(composer.SelectHome), p);
    try b.add("shift-cmd-right", act(composer.SelectEnd), p);
    try b.add("cmd-backspace", act(composer.DeleteToLineStart), p);
    const word: []const u8 = if (b.mac) "alt" else "ctrl";
    try b.add(try b.fmt("{s}-backspace", .{word}), act(composer.DeleteWordLeft), p);
    try b.add(try b.fmt("{s}-delete", .{word}), act(composer.DeleteWordRight), p);
    try b.add(try b.fmt("{s}-left", .{word}), act(composer.WordLeft), p);
    try b.add(try b.fmt("{s}-right", .{word}), act(composer.WordRight), p);
    try b.add(try b.fmt("shift-{s}-left", .{word}), act(composer.SelectWordLeft), p);
    try b.add(try b.fmt("shift-{s}-right", .{word}), act(composer.SelectWordRight), p);
    for ([_][]const u8{ "cmd", "ctrl" }) |prefix| {
        try b.add(try b.fmt("{s}-a", .{prefix}), act(composer.SelectAll), p);
        try b.add(try b.fmt("{s}-c", .{prefix}), act(composer.Copy), p);
        try b.add(try b.fmt("{s}-x", .{prefix}), act(composer.Cut), p);
        try b.add(try b.fmt("{s}-v", .{prefix}), act(composer.Paste), p);
        try b.add(try b.fmt("{s}-z", .{prefix}), act(composer.Undo), p);
        try b.add(try b.fmt("shift-{s}-z", .{prefix}), act(composer.Redo), p);
    }

    try inputBindings(b, generic_composer_context);
    try b.add("enter", act(composer.Submit), generic_composer_context);

    try inputBindings(b, message_composer_context);
    const modified = try b.platform("mod-enter");
    switch (send_behavior) {
        .enter => {
            try b.add("enter", act(composer.Submit), message_composer_context);
            try b.add(modified, act(composer.ModifiedSubmit), message_composer_context);
        },
        .@"mod-enter" => {
            try b.add("enter", act(composer.MessageNewlineOrAccept), message_composer_context);
            try b.add(modified, act(composer.ModifiedSubmit), message_composer_context);
        },
    }
}

/// `app_menus::app_key_bindings(macos)`.
fn appMenuBindings(b: *Builder) !void {
    try b.add(if (b.mac) "cmd-," else "ctrl-,", act(shell.OpenSettings), null);
    if (b.mac) {
        try b.add("cmd-q", act(actions.zeron.Quit), null);
        try b.add("cmd-h", act(actions.zeron.Hide), null);
        try b.add("alt-cmd-h", act(actions.zeron.HideOthers), null);
        try b.add("cmd-m", act(actions.zeron.Minimize), null);
        try b.add("cmd-w", act(actions.zeron.CloseWindow), null);
    }
}

/// `browser::bind_keys`: fixed browser chords unless a customized app
/// shortcut already uses the same keystroke.
fn browserBindings(b: *Builder, keymap: *const KeymapConfig) !void {
    const Avail = struct {
        fn check(bb: *Builder, km: *const KeymapConfig, combo: []const u8, own: ?ShortcutId) !bool {
            if (combo.len == 0) return false;
            const candidate = try bb.platform(combo);
            for (ShortcutId.all) |id| {
                if (own) |o| if (o.eql(id)) continue;
                const existing = try bb.platform(km.get(id));
                if (keystrokeEql(bb.arena, existing, candidate)) return false;
            }
            return true;
        }
    };
    const fixed = [_]struct { []const u8, Binding.Act }{
        .{ "mod-l", act(actions.browser.FocusAddress) },
        .{ "mod-t", act(actions.browser.NewTab) },
        .{ "mod-w", act(actions.browser.CloseTab) },
        .{ "mod-[", act(actions.browser.Back) },
        .{ "mod-]", act(actions.browser.Forward) },
    };
    for (fixed) |f| {
        if (try Avail.check(b, keymap, f[0], null)) try b.add(try b.platform(f[0]), f[1], browser_context);
    }
    const reload = keymap.get(.browser_reload);
    if (try Avail.check(b, keymap, reload, .browser_reload)) {
        const ks = try b.platform(reload);
        if (parses(b.arena, ks)) try b.add(ks, act(actions.browser.Reload), browser_context);
    }
}

/// The full default binding list for a platform, in installation order.
/// Strings live in `arena`.
pub fn defaultBindings(arena: Allocator, mac: bool, keymap: *const KeymapConfig, send_behavior: ComposerSendBehavior) ![]Binding {
    var b: Builder = .{ .arena = arena, .mac = mac };
    try composerBindings(&b, send_behavior);
    try b.add(try b.validOrDefault(keymap.toggleDictation, ShortcutId.defaultComboOn(.toggle_dictation, mac)), act(composer.ToggleDictation), message_composer_context);
    try appMenuBindings(&b);
    const Row = struct { []const u8, []const u8, Binding.Act };
    const rows = [_]Row{
        .{ keymap.randomWallpaper, "mod-u", act(shell.RandomWallpaper) },
        .{ keymap.saveFile, "mod-s", act(shell.SaveFile) },
        .{ keymap.toggleSidebar, "mod-b", act(shell.ToggleSidebar) },
        .{ keymap.toggleChanges, "mod-r", act(shell.ToggleChanges) },
        .{ keymap.toggleFiles, "mod-e", act(shell.ToggleFiles) },
        .{ keymap.toggleTerminal, "mod-j", act(actions.terminal.ToggleTerminal) },
        .{ keymap.newSession, "mod-n", act(shell.NewSession) },
        .{ keymap.nextSession, ShortcutId.defaultComboOn(.next_session, mac), act(shell.NextSession) },
        .{ keymap.prevSession, ShortcutId.defaultComboOn(.prev_session, mac), act(shell.PrevSession) },
        .{ keymap.archiveSession, "mod-shift-a", act(shell.ArchiveSession) },
        .{ keymap.newProject, ShortcutId.defaultComboOn(.new_project, mac), act(shell.AddSpacePalette) },
    };
    for (rows) |r| try b.add(try b.validOrDefault(r[0], r[1]), r[2], null);
    // Fixed: mod-k summons (and dismisses) the command palette.
    try b.add(try b.platform("mod-k"), act(shell.ToggleCommandPalette), null);
    try b.add(try b.validOrDefault(keymap.openModelPicker, "mod-/"), act(shell.OpenModelPicker), null);
    try browserBindings(&b, keymap);
    // mod-1..9 open the sidebar's first nine rows; a cleared slot binds nothing.
    for (0..settings.jump_slots) |slot| {
        const id: ShortcutId = .{ .jump_session = slot };
        const combo = keymap.get(id);
        if (combo.len == 0) continue;
        try b.add(try b.validOrDefault(combo, id.defaultComboOn(mac)), .{ .jump = slot }, null);
    }
    return b.list.items;
}

/// `shell::apply_keymap`: clear every binding and install the defaults for
/// this platform from `keymap`.
pub fn applyKeymap(app: *zpui.App, keymap: *const KeymapConfig, send_behavior: ComposerSendBehavior) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const bindings = try defaultBindings(arena_state.allocator(), settings.is_mac, keymap, send_behavior);
    app.keymap.clear();
    for (bindings) |b| {
        const any = try b.action.build(app.gpa);
        try app.keymap.add(try zpui.KeyBinding.init(app.gpa, b.keystrokes, any, b.context));
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn find(list: []const Binding, name: []const u8, context: ?[]const u8) ?Binding {
    for (list) |b| {
        if (!std.mem.eql(u8, b.action.name(), name)) continue;
        if (context == null and b.context != null) continue;
        if (context) |c| if (b.context == null or !std.mem.eql(u8, c, b.context.?)) continue;
        return b;
    }
    return null;
}

fn expectBound(list: []const Binding, name: []const u8, context: ?[]const u8, keystrokes: []const u8) !void {
    const b = find(list, name, context) orelse {
        std.debug.print("missing binding for {s}\n", .{name});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(keystrokes, b.keystrokes);
}

test "default bindings per platform match Rust" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const km: KeymapConfig = .{};
    inline for (.{ true, false }) |mac| {
        var keymap = km;
        // Defaults are platform-specific for these two; mirror the platform.
        keymap.nextSession = ShortcutId.defaultComboOn(.next_session, mac);
        keymap.prevSession = ShortcutId.defaultComboOn(.prev_session, mac);
        keymap.captureAppshot = ShortcutId.defaultComboOn(.capture_appshot, mac);
        const list = try defaultBindings(a, mac, &keymap, .enter);
        const p = if (mac) "cmd" else "ctrl";
        try expectBound(list, "shell::ToggleCommandPalette", null, p ++ "-k");
        try expectBound(list, "shell::ToggleSidebar", null, p ++ "-b");
        try expectBound(list, "shell::ToggleChanges", null, p ++ "-r");
        try expectBound(list, "shell::ToggleFiles", null, p ++ "-e");
        try expectBound(list, "terminal::ToggleTerminal", null, p ++ "-j");
        try expectBound(list, "shell::NewSession", null, p ++ "-n");
        try expectBound(list, "shell::AddSpacePalette", null, p ++ "-shift-n");
        try expectBound(list, "shell::OpenModelPicker", null, p ++ "-/");
        try expectBound(list, "shell::NextSession", null, "ctrl-tab");
        try expectBound(list, "shell::PrevSession", null, "ctrl-shift-tab");
        try expectBound(list, "shell::ArchiveSession", null, p ++ "-shift-a");
        try expectBound(list, "shell::RandomWallpaper", null, p ++ "-u");
        try expectBound(list, "shell::SaveFile", null, p ++ "-s");
        try expectBound(list, "shell::OpenSettings", null, p ++ "-,");
        try expectBound(list, "composer::ToggleDictation", message_composer_context, p ++ "-d");
        try expectBound(list, "composer::ModifiedSubmit", message_composer_context, p ++ "-enter");
        try expectBound(list, "composer::Submit", message_composer_context, "enter");
        try expectBound(list, "browser::FocusAddress", browser_context, p ++ "-l");
        try expectBound(list, "browser::Reload", browser_context, p ++ "-shift-r");
        try expectBound(list, "composer::WordLeft", generic_composer_context, (if (mac) "alt" else "ctrl") ++ "-left");
        try testing.expectEqual(mac, find(list, "zeron::Quit", null) != null);
        // mod-1..9 jump slots.
        var jumps: usize = 0;
        for (list) |b| if (b.action == .jump) {
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}-{d}", .{ p, b.action.jump + 1 }), b.keystrokes);
            jumps += 1;
        };
        try testing.expectEqual(@as(usize, 9), jumps);
        // Every binding parses as zpui keystrokes + context predicate.
        for (list) |b| {
            var kb = try zpui.KeyBinding.init(testing.allocator, b.keystrokes, try b.action.build(testing.allocator), b.context);
            kb.deinit(testing.allocator);
        }
    }
}

test "customized combos, fallbacks, cleared slots, browser conflicts, send behavior" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var km: KeymapConfig = .{};
    km.toggleSidebar = "mod-shift-s"; // customized
    km.newSession = ""; // unparseable → default
    km.jumpSession[3] = ""; // cleared slot → unbound
    km.toggleFiles = "mod-l"; // takes the browser's address chord
    const list = try defaultBindings(a, false, &km, .@"mod-enter");
    try expectBound(list, "shell::ToggleSidebar", null, "ctrl-shift-s");
    try expectBound(list, "shell::NewSession", null, "ctrl-n");
    try expectBound(list, "shell::ToggleFiles", null, "ctrl-l");
    try testing.expect(find(list, "browser::FocusAddress", browser_context) == null);
    try expectBound(list, "composer::MessageNewlineOrAccept", message_composer_context, "enter");
    var jumps: usize = 0;
    for (list) |b| if (b.action == .jump) {
        try testing.expect(b.action.jump != 3);
        jumps += 1;
    };
    try testing.expectEqual(@as(usize, 8), jumps);
}

test "applyKeymap installs bindings that dispatch by keystroke" {
    const app = try zpui.App.initTest(testing.allocator);
    defer app.deinit();
    try actions.registerAll(app);
    try applyKeymap(app, &.{}, .enter);
    try testing.expect(app.keymap.bindings.items.len > 100);
    const ks = try zpui.core.parseKeystroke(testing.allocator, if (settings.is_mac) "cmd-k" else "ctrl-k");
    defer zpui.core.keymap.freeKeystroke(testing.allocator, ks);
    var match = try app.keymap.bindingsForInput(testing.allocator, &.{ks}, &.{});
    defer match.deinit(testing.allocator);
    try testing.expect(match.bindings.items.len >= 1);
    try testing.expect(match.bindings.items[0].action.is(shell.ToggleCommandPalette));
}
