//! `ComposerView` on zpui's headless test platform with a real `AppState`
//! whose engine never connects (no server, no spawn): layout flips, the
//! model chip from an injected catalog, slash completions, the offline send
//! failure and the picker popover.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const input_mod = @import("zeron_input");
const composer_mod = @import("composer.zig");
const metrics = @import("metrics.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;
const ComposerView = composer_mod.ComposerView;
const testing = std.testing;
const div = zpui.div;
const px = zpui.px;

const Host = struct {
    composer: Entity(ComposerView),
    events: std.ArrayList(composer_mod.ComposerEvent) = .empty,
    sub: zpui.Subscription,

    fn init(state: Entity(model.AppState), window: *Window, cx: *Context(Host)) !Host {
        const composer = try cx.newWith(ComposerView, ComposerView.init, .{state});
        composer.update(cx, ComposerView.focusInput, .{window});
        return .{ .composer = composer, .sub = try cx.subscribe(composer, Host.onEvent) };
    }

    pub fn deinit(self: *Host, cx: *App) void {
        self.sub.deinit();
        self.events.deinit(cx.gpa);
        self.composer.release(cx);
    }

    fn onEvent(self: *Host, _: Entity(ComposerView), ev: *const composer_mod.ComposerEvent, cx: *Context(Host)) void {
        self.events.append(cx.gpa(), ev.*) catch {};
    }

    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        return div().size(px(800)).flex().flexCol().justifyEnd().child(self.composer);
    }
};

const Fixture = struct {
    app: *App,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(Host),
    tw: *TestWindow,

    fn init() !Fixture {
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ testing.io, model.engine_state.Config{
            .port = 1, // nothing listens; never connects in the test dispatcher
            .zeron_path = null,
            .reconnect = false,
        } });
        const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 800, .height = 600 } } }, Host, Host.init, .{state});
        const w = handle.window(app).?;
        return .{ .app = app, .state = state, .handle = handle, .tw = TestWindow.of(w.platform_window) };
    }

    fn deinit(f: *Fixture) void {
        f.state.release(f.app);
        f.app.deinit();
    }

    fn host(f: *Fixture) *const Host {
        return f.handle.rootView(f.app).?.read(f.app);
    }

    fn composer(f: *Fixture) *const ComposerView {
        return f.host().composer.read(f.app);
    }

    fn input(f: *Fixture) *const input_mod.TextInput {
        return f.composer().input.read(f.app);
    }

    fn typeChars(f: *Fixture, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const ch = s[i..][0..n];
            _ = f.tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = ch, .key_char = ch } } });
            i += n;
        }
    }

    fn injectCatalog(f: *Fixture) !void {
        const harnesses =
            \\[{"id":"claude-code","name":"Claude Code","supportsSteering":true,"steeringMode":"step-boundary","reasoningLevels":["low","medium","high","max"]},
            \\ {"id":"codex","name":"Codex","supportsSteering":true,"steeringMode":"turn-boundary","reasoningLevels":["low","medium","high"]}]
        ;
        const models =
            \\[{"id":"claude-fable-5","label":"Fable"},{"id":"claude-sonnet-4-6","label":"Sonnet 4.6"}]
        ;
        const catalog = f.state.read(f.app).catalog;
        var l = catalog.lease(f.app);
        defer l.end();
        const hv = try std.json.parseFromSlice(std.json.Value, testing.allocator, harnesses, .{});
        defer hv.deinit();
        const mv = try std.json.parseFromSlice(std.json.Value, testing.allocator, models, .{});
        defer mv.deinit();
        const status = model.status;
        l.value.harnesses = try status.OwnedJson([]@import("zeron_engine").protocol.HarnessDescriptor).fromValue(testing.allocator, hv.value);
        l.value.models.set(.@"claude-code", try status.OwnedJson([]@import("zeron_engine").protocol.Model).fromValue(testing.allocator, mv.value));
        l.cx.notify();
    }
};

test "compact model list: provider tabs are its groups, starred first" {
    // pickers.rs: "The list's tabs are its provider groups, in list order;
    // starring adds a Starred tab ahead of them".
    var f = try Fixture.init();
    defer f.deinit();
    try f.injectCatalog();
    const MP = @import("model_picker.zig").ModelPicker;
    const protocol = @import("zeron_engine").protocol;
    {
        const catalog = f.state.read(f.app).catalog;
        var l = catalog.lease(f.app);
        defer l.end();
        const mv = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"gpt-a","label":"GPT A"},{"id":"gpt-b","label":"GPT B"}]
        , .{});
        defer mv.deinit();
        l.value.models.set(.codex, try model.status.OwnedJson([]protocol.Model).fromValue(testing.allocator, mv.value));
        l.cx.notify();
    }
    const picker = f.composer().picker;
    var gbuf: [8]MP.Group = undefined;
    var rbuf: [16]MP.Row = undefined;
    {
        const gs = picker.read(f.app).groups(f.app, &gbuf);
        try testing.expectEqual(@as(usize, 2), gs.len);
        try testing.expectEqual(@as(?protocol.HarnessId, .@"claude-code"), gs[0].harness);
        try testing.expectEqual(@as(usize, 0), gs[0].start);
        try testing.expectEqual(@as(?protocol.HarnessId, .codex), gs[1].harness);
        try testing.expectEqual(@as(usize, 2), gs[1].start);
    }
    // Starring a model adds the Starred group (and its row) ahead.
    const favs = [_]@import("zeron_model").composer_defaults.FavoriteModel{.{ .harness = .codex, .model = "gpt-b" }};
    const defaults: @import("run_config.zig").ComposerDefaults = .{ .favorites = &favs };
    picker.update(f.app, MP.setDefaults, .{&defaults});
    {
        const gs = picker.read(f.app).groups(f.app, &gbuf);
        try testing.expectEqual(@as(usize, 3), gs.len);
        try testing.expectEqual(@as(?protocol.HarnessId, null), gs[0].harness);
        try testing.expectEqual(@as(usize, 1), gs[1].start);
        try testing.expectEqual(@as(usize, 3), gs[2].start);
        const rows = picker.read(f.app).rows(f.app, &rbuf);
        try testing.expectEqualStrings("gpt-b", rows[0].model.id);
        try testing.expectEqualStrings("gpt-a", rows[3].model.id);
    }
    picker.update(f.app, MP.setDefaults, .{null});
}

test "compact pill until a newline, then expanded with auto-grow" {
    var f = try Fixture.init();
    defer f.deinit();
    // New-thread canvas: always expanded (120px).
    try testing.expect(f.composer().last_rendered_height >= metrics.composer_min_height - 0.01);
    try testing.expectApproxEqAbs(metrics.composer_min_height, f.composer().last_rendered_height, 0.01);
    f.typeChars("hello");
    try testing.expectEqualStrings("hello", f.input().text());
    f.tw.typeKey("shift-enter");
    f.typeChars("a");
    f.tw.typeKey("shift-enter");
    f.typeChars("b");
    f.tw.typeKey("shift-enter");
    f.typeChars("c");
    // Four lines: content 4 × 22.75 + 20 padding + 44 actions + 2 border.
    f.app.advanceClock(400 * std.time.ns_per_ms);
    try testing.expectApproxEqAbs(metrics.composerTotalHeight(4 * 22.75), f.composer().last_rendered_height, 0.5);
}

test "offline send keeps the draft and shows the Engine-not-connected warning" {
    var f = try Fixture.init();
    defer f.deinit();
    f.typeChars("ship it");
    f.tw.typeKey("enter");
    try testing.expectEqualStrings("Engine not connected", f.composer().failure.items);
    try testing.expect(f.composer().failure_warning);
    try testing.expectEqualStrings("ship it", f.input().text());
}

test "slash completions: token, navigation, accept emits the workspace command" {
    var f = try Fixture.init();
    defer f.deinit();
    f.typeChars("/se");
    try testing.expect(f.input().mention_open);
    try testing.expect(f.input().mention_has_selection);
    f.tw.typeKey("enter"); // accepts instead of submitting
    try testing.expectEqualStrings("", f.input().text());
    const evs = f.host().events.items;
    try testing.expect(evs.len >= 1);
    try testing.expectEqual(@as(@import("slash.zig").WorkspaceCommand, .settings), evs[evs.len - 1].workspace_command);
    // Escape dismisses until the token is edited.
    f.typeChars("/n");
    try testing.expect(f.input().mention_has_selection);
    f.tw.typeKey("escape");
    try testing.expect(!f.input().mention_has_selection);
}

test "model chip resolves from the catalog; picker popover lists and picks models" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.injectCatalog();
    const picker = f.composer().picker;
    const p = picker.read(f.app);
    const r = p.resolved(f.app);
    try testing.expectEqual(@import("zeron_engine").protocol.HarnessId.@"claude-code", r.harness.?);
    try testing.expectEqualStrings("claude-fable-5", r.model.?);
    try testing.expectEqual(@import("zeron_engine").protocol.ReasoningLevel.high, r.reasoning.?);
    // Open the popover via the handle and pick the second row with the keyboard.
    const w = f.handle.window(f.app).?;
    _ = picker.update(f.app, @import("model_picker.zig").ModelPicker.toggle, .{w});
    try testing.expect(picker.read(f.app).isOpen());
    f.tw.typeKey("down");
    f.tw.typeKey("enter");
    try testing.expect(!picker.read(f.app).isOpen());
    try testing.expectEqualStrings("claude-sonnet-4-6", picker.read(f.app).resolved(f.app).model.?);
}
