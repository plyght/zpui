//! Composer dictation on zpui's headless test platform (Rust
//! composer_dictation_tests.rs, the `Composer` half): the microphone's
//! states and accessible names, hold to talk from the pointer, the tap
//! explanation, the voice track's live status, Cancel in the attachment
//! slot, outcome strips with Dismiss, and send-after-final. The app's
//! `dictation.Service` is replaced by a scripted transcriber.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const input_mod = @import("zeron_input");
const composer_mod = @import("composer.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;
const ComposerView = composer_mod.ComposerView;
const dict = input_mod.dictation;
const a11y = zpui.a11y;
const testing = std.testing;
const div = zpui.div;
const px = zpui.px;

const Fake = struct {
    events: [16]dict.Event = undefined,
    len: usize = 0,
    head: usize = 0,
    finishes: usize = 0,
    drops: usize = 0,
    starts: usize = 0,

    const vtable: dict.Transcriber.VTable = .{ .poll = poll, .finish = finish, .level = level, .deinit = drop };

    fn push(self: *Fake, evs: []const dict.Event) void {
        for (evs) |e| {
            self.events[self.len] = e;
            self.len += 1;
        }
    }
    fn poll(ctx: *anyopaque) ?dict.Event {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.head == self.len) return null;
        self.head += 1;
        return self.events[self.head - 1];
    }
    fn finish(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.finishes += 1;
    }
    fn level(_: *anyopaque) f32 {
        return 0.05;
    }
    fn drop(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.drops += 1;
    }
};

var fake: Fake = .{};
var service_on = true;
var pending_permission = false;

fn svcEnabled(_: ?*anyopaque, _: *App) bool {
    return service_on;
}
fn svcStart(_: ?*anyopaque, _: *App) ?dict.Transcriber {
    fake = .{ .starts = fake.starts + 1 };
    return .{ .ctx = &fake, .vtable = &Fake.vtable };
}
fn svcPending(_: ?*anyopaque) bool {
    return pending_permission;
}
fn svcBinding(_: ?*anyopaque, _: *App, _: []u8) []const u8 {
    return "";
}

const Host = struct {
    composer: Entity(ComposerView),

    fn init(state: Entity(model.AppState), window: *Window, cx: *Context(Host)) !Host {
        const composer = try cx.newWith(ComposerView, ComposerView.init, .{state});
        composer.update(cx, ComposerView.focusInput, .{window});
        return .{ .composer = composer };
    }
    pub fn deinit(self: *Host, cx: *App) void {
        self.composer.release(cx);
    }
    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        return div().sizeFull().flex().flexCol().justifyEnd().child(self.composer);
    }
};

const Fixture = struct {
    app: *App,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(Host),
    tw: *TestWindow,

    fn init(enabled: bool) !Fixture {
        fake = .{};
        service_on = enabled;
        pending_permission = false;
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        try app.setGlobal(dict.Service{ .enabled = svcEnabled, .start = svcStart, .permission_pending = svcPending, .binding = svcBinding });
        const state = try app.newWith(model.AppState, model.AppState.init, .{ testing.io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false } });
        const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 800, .height = 600 } } }, Host, Host.init, .{state});
        const w = handle.window(app).?;
        const tw = TestWindow.of(w.platform_window);
        tw.simulateA11yActivation(true);
        var f: Fixture = .{ .app = app, .state = state, .handle = handle, .tw = tw };
        f.redraw();
        return f;
    }
    fn deinit(f: *Fixture) void {
        f.state.release(f.app);
        f.app.deinit();
    }
    fn composer(f: *Fixture) *const ComposerView {
        return f.handle.rootView(f.app).?.read(f.app).composer.read(f.app);
    }
    fn input(f: *Fixture) *const input_mod.TextInput {
        return f.composer().input.read(f.app);
    }
    fn phase(f: *Fixture) dict.PhaseTag {
        return f.input().dictation.phase;
    }
    fn redraw(f: *Fixture) void {
        f.app.runUntilParked();
        f.tw.frame(false);
    }
    fn tree(f: *Fixture) *const a11y.Tree {
        return f.handle.window(f.app).?.a11yTree();
    }
    fn find(f: *Fixture, role: a11y.Role, name: []const u8) ?*const a11y.Node {
        const t = f.tree();
        for (t.nodes.items) |*n| {
            if (n.role != role) continue;
            const got = t.name(n) orelse continue;
            if (std.mem.eql(u8, got, name)) return n;
        }
        return null;
    }
    fn expect(f: *Fixture, role: a11y.Role, name: []const u8) !*const a11y.Node {
        return f.find(role, name) orelse {
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            f.tree().dump(&out.writer) catch {};
            std.debug.print("no {t} \"{s}\" in tree:\n{s}\n", .{ role, name, out.written() });
            return error.MissingNode;
        };
    }
    fn center(n: *const a11y.Node) zpui.Point(f32) {
        return .{ .x = n.bounds.origin.x + n.bounds.size.width / 2, .y = n.bounds.origin.y + n.bounds.size.height / 2 };
    }
    fn pressMic(f: *Fixture) !void {
        const mic = try f.expect(.button, "Hold to dictate");
        _ = f.tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = center(mic), .click_count = 1 } });
        f.redraw();
    }
    /// Release the pointer somewhere else (`on_mouse_up_out` also ends the hold).
    fn releasePointer(f: *Fixture) void {
        _ = f.tw.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = 5, .y = 5 } } });
        f.redraw();
    }
    /// Let the 40 ms poll drain the script.
    fn tick(f: *Fixture, ms: u64) void {
        f.app.advanceClock(ms * std.time.ns_per_ms);
        f.redraw();
    }
    fn typeChars(f: *Fixture, s: []const u8) void {
        for (0..s.len) |i| _ = f.tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = s[i .. i + 1], .key_char = s[i .. i + 1] } } });
        f.redraw();
    }
};

test "microphone appears only when dictation is enabled and ready" {
    {
        var f = try Fixture.init(false);
        defer f.deinit();
        try testing.expect(f.find(.button, "Hold to dictate") == null);
        _ = try f.expect(.button, "Attach images");
    }
    var f = try Fixture.init(true);
    defer f.deinit();
    const mic = try f.expect(.button, "Hold to dictate");
    try testing.expectEqual(a11y.Toggled.off, mic.toggled.?);
}

test "pointer hold: listening track, release transcribes into the draft" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.typeChars("note: ");
    try f.pressMic();
    try testing.expectEqual(dict.PhaseTag.requesting, f.phase());
    try testing.expectEqual(@as(usize, 1), fake.starts);
    // The mic names the action, the paperclip becomes Cancel.
    const stop = try f.expect(.button, "Release to transcribe");
    try testing.expectEqual(a11y.Toggled.on, stop.toggled.?);
    _ = try f.expect(.button, "Cancel dictation");
    f.tick(100); // the track unrolls from Stop with the morph
    _ = try f.expect(.status, "Getting ready\u{2026}. Wait for Listening before speaking.");
    fake.push(&.{.listening});
    f.tick(500);
    try testing.expectEqual(dict.PhaseTag.listening, f.phase());
    _ = try f.expect(.status, "Listening. Release when you\u{2019}re done \u{b7} Up to 1 minute");
    f.releasePointer();
    try testing.expectEqual(dict.PhaseTag.finalizing, f.phase());
    try testing.expectEqual(@as(usize, 1), fake.finishes);
    _ = try f.expect(.status, "Transcribing\u{2026}. Processing on this device.");
    _ = try f.expect(.button, "Transcribing");
    fake.push(&.{.{ .final = "hello world" }});
    f.tick(50);
    try testing.expectEqualStrings("note: hello world", f.input().text());
    try testing.expectEqual(dict.PhaseTag.idle, f.phase());
    try testing.expectEqual(@as(usize, 1), fake.drops);
    // The morph settles back to the resting microphone; nothing was sent.
    f.tick(600);
    _ = try f.expect(.button, "Hold to dictate");
    _ = try f.expect(.button, "Attach images");
    try testing.expectEqual(@as(usize, 0), f.composer().failure.items.len);
}

test "a tap explains hold to talk without transcribing" {
    var f = try Fixture.init(true);
    defer f.deinit();
    try f.pressMic();
    f.releasePointer();
    try testing.expectEqual(dict.PhaseTag.tapped, f.phase());
    try testing.expectEqual(@as(usize, 0), fake.finishes);
    try testing.expectEqual(@as(usize, 1), fake.drops);
    _ = try f.expect(.status, "Hold to dictate. Keep holding the microphone or the shortcut while you speak.");
    const dismiss = try f.expect(.button, "Dismiss dictation message");
    f.tw.simulateA11yAction(.{ .target = dismiss.id, .action = .click });
    f.redraw();
    try testing.expectEqual(dict.PhaseTag.idle, f.phase());
    try testing.expect(f.find(.button, "Dismiss dictation message") == null);
}

test "a release that only answered the permission prompt records nothing" {
    var f = try Fixture.init(true);
    defer f.deinit();
    pending_permission = true;
    try f.pressMic();
    f.tick(400);
    f.releasePointer();
    try testing.expectEqual(dict.PhaseTag.idle, f.phase());
    try testing.expectEqual(@as(usize, 1), fake.drops);
}

test "failures read under the pill and Dismiss clears them; the draft stays" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.typeChars("keep");
    try f.pressMic();
    fake.push(&.{ .listening, .{ .failed = "Microphone disconnected. Your draft is safe." } });
    f.tick(500);
    try testing.expectEqual(dict.PhaseTag.failed, f.phase());
    _ = try f.expect(.status, "Dictation stopped. Microphone disconnected. Your draft is safe.");
    _ = try f.expect(.button, "Hold to retry dictation");
    try testing.expectEqualStrings("keep", f.input().text());
    f.releasePointer(); // the hold already ended with the session
    try testing.expectEqual(dict.PhaseTag.failed, f.phase());
    f.tw.simulateA11yAction(.{ .target = (try f.expect(.button, "Dismiss dictation message")).id, .action = .click });
    f.redraw();
    try testing.expectEqual(dict.PhaseTag.idle, f.phase());
}

test "Cancel in the attachment slot keeps the draft and drops capture" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.typeChars("draft");
    try f.pressMic();
    fake.push(&.{ .listening, .{ .partial = " spoken" } });
    f.tick(500);
    try testing.expectEqualStrings("draft spoken", f.input().text());
    f.tw.simulateA11yAction(.{ .target = (try f.expect(.button, "Cancel dictation")).id, .action = .click });
    f.redraw();
    try testing.expectEqual(dict.PhaseTag.idle, f.phase());
    try testing.expectEqual(@as(usize, 1), fake.drops);
    try testing.expectEqualStrings("draft spoken", f.input().text());
    f.releasePointer();
    try testing.expectEqual(@as(usize, 0), fake.finishes);
}

test "assistive Click starts then finishes; Enter while dictating sends after the final" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.tw.simulateA11yAction(.{ .target = (try f.expect(.button, "Hold to dictate")).id, .action = .click });
    f.redraw();
    fake.push(&.{.listening});
    f.tick(100);
    try testing.expectEqual(dict.PhaseTag.listening, f.phase());
    // Send stops capture once and waits for the transcript.
    f.tw.typeKey("enter");
    f.tw.typeKey("enter");
    f.redraw();
    try testing.expectEqual(dict.PhaseTag.finalizing, f.phase());
    try testing.expectEqual(@as(usize, 1), fake.finishes);
    try testing.expectEqual(@as(usize, 0), f.composer().failure.items.len);
    fake.push(&.{.{ .final = "ship it" }});
    f.tick(50);
    try testing.expectEqualStrings("ship it", f.input().text());
    // The send ran once, against the (offline) engine.
    try testing.expectEqualStrings("Engine not connected", f.composer().failure.items);
}

test "silence explains itself and never sends the existing draft" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.typeChars("existing");
    f.tw.simulateA11yAction(.{ .target = (try f.expect(.button, "Hold to dictate")).id, .action = .click });
    f.redraw();
    f.tw.typeKey("enter");
    fake.push(&.{.{ .final = "" }});
    f.tick(50);
    try testing.expectEqual(dict.PhaseTag.no_speech, f.phase());
    _ = try f.expect(.status, "No speech detected. Check your microphone, then try again.");
    try testing.expectEqualStrings("existing", f.input().text());
    try testing.expectEqual(@as(usize, 0), f.composer().failure.items.len);
}

test "turning Voice off stops a live session" {
    var f = try Fixture.init(true);
    defer f.deinit();
    try f.pressMic();
    service_on = false;
    // Any settings change notifies the composer; here the service flips and
    // the next render hides the microphone.
    f.redraw();
    try testing.expect(f.find(.button, "Hold to dictate") == null);
}

test "voice tween and waveform layout" {
    const voice = @import("voice.zig");
    var tw: voice.Tween = .{};
    tw.retarget(1, 0, false);
    try testing.expectEqual(@as(f32, 0), tw.value(0));
    try testing.expect(tw.value(voice.morph_ns / 2) > 0.5);
    try testing.expectEqual(@as(f32, 1), tw.value(voice.morph_ns));
    tw.retarget(0, voice.morph_ns / 4, false);
    const mid = tw.value(voice.morph_ns / 4);
    try testing.expect(mid > 0 and mid < 1); // reverses without a jump
    tw.retarget(1, 0, true);
    try testing.expect(tw.settled(0));
    // Waiting: a baseline of dots at the floor; live bars rise with the level.
    const theme = zpui.hsla(0, 0, 1, 1);
    var buf: [128]voice.Quad = undefined;
    const waiting = voice.layout(.{ .bars = &.{}, .mode = .waiting, .ink = theme, .quiet = theme, .intro = 1, .collapse = 0, .motion = false, .seconds = 0 }, 0, 0, 120, 16, &buf);
    try testing.expect(waiting.len > 10);
    for (waiting) |q| try testing.expectApproxEqAbs(@max(dict.floor * 16 * 1.0, voice.bar_width), q.h, 0.01);
    const bars = [_]dict.Bar{ .{ .age = 2, .amplitude = 1 }, .{ .age = 3, .amplitude = 0.5 } };
    var buf2: [128]voice.Quad = undefined;
    const live = voice.layout(.{ .bars = &bars, .mode = .live, .ink = theme, .quiet = theme, .intro = 1, .collapse = 0, .motion = false, .seconds = 0 }, 0, 0, 120, 16, &buf2);
    try testing.expectApproxEqAbs(@as(f32, 16), live[0].h, 0.01);
    try testing.expect(live[1].h < live[0].h and live[1].h > live[2].h);
    // The newest bar sits at the trailing edge.
    try testing.expectApproxEqAbs(@as(f32, 120 - voice.bar_width), live[0].x, 0.01);
}
