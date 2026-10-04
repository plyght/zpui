//! View-level tests for `TextInput` on zpui's headless test platform (the fake
//! text system lays narrow characters out 10px wide and CJK / emoji 20px wide
//! at 16px, so a 16px font gives exact geometry).

const std = @import("std");
const zpui = @import("zpui");
const actions = @import("zeron_actions");
const ti = @import("text_input.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;
const TextInput = ti.TextInput;
const testing = std.testing;
const div = zpui.div;
const px = zpui.px;

const Host = struct {
    input: Entity(TextInput),
    events: std.ArrayList(ti.TextInputEvent) = .empty,
    sub: zpui.Subscription,
    width: f32,

    const Args = struct { opts: ti.Options, width: f32 = 200 };

    fn init(args: Args, window: *Window, cx: *Context(Host)) !Host {
        const input = try cx.newWith(TextInput, TextInput.init, .{args.opts});
        window.focus(input.read(cx).focus);
        return .{ .input = input, .sub = try cx.subscribe(input, Host.onEvent), .width = args.width };
    }

    pub fn deinit(self: *Host, cx: *App) void {
        self.sub.deinit();
        self.events.deinit(cx.gpa);
        self.input.release(cx);
    }

    fn onEvent(self: *Host, _: Entity(TextInput), ev: *const ti.TextInputEvent, cx: *Context(Host)) void {
        self.events.append(cx.gpa(), ev.*) catch {};
    }

    fn count(self: *const Host, tag: std.meta.Tag(ti.TextInputEvent)) usize {
        var n: usize = 0;
        for (self.events.items) |e| if (e == tag) {
            n += 1;
        };
        return n;
    }

    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        // The input sits at (10, 10) inside the window.
        return div().size(px(400)).p(px(10)).child(div().w(px(self.width)).child(self.input));
    }
};

const test_opts: ti.Options = .{
    .placeholder = "Do anything…",
    .text_size = 16,
    .line_height = 20,
    .font_family = "Test",
    .max_content_height = 60,
};

const Fixture = struct {
    app: *App,
    handle: zpui.WindowHandle(Host),
    w: *Window,
    tw: *TestWindow,

    fn init(opts: ti.Options, width: f32) !Fixture {
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } }, Host, Host.init, .{Host.Args{ .opts = opts, .width = width }});
        const w = handle.window(app).?;
        return .{ .app = app, .handle = handle, .w = w, .tw = TestWindow.of(w.platform_window) };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
    }

    fn host(f: *Fixture) *const Host {
        return f.handle.rootView(f.app).?.read(f.app);
    }

    fn input(f: *Fixture) *const TextInput {
        return f.host().input.read(f.app);
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

    /// Types a keystroke written with Linux bindings; on macOS, word motion
    /// becomes alt-* and the remaining ctrl-* shortcuts become cmd-*.
    fn key(f: *Fixture, comptime ks: []const u8) void {
        f.tw.typeKey(comptime platformKey(ks));
    }

    fn platformKey(comptime ks: []const u8) []const u8 {
        if (@import("builtin").os.tag != .macos) return ks;
        const word = [_][]const u8{ "ctrl-left", "ctrl-right", "ctrl-backspace", "ctrl-delete" };
        inline for (word) |w| {
            if (std.mem.endsWith(u8, ks, w)) return ks[0 .. ks.len - w.len] ++ "alt-" ++ w["ctrl-".len..];
        }
        if (std.mem.find(u8, ks, "ctrl-")) |i| return ks[0..i] ++ "cmd-" ++ ks[i + "ctrl-".len ..];
        return ks;
    }

    fn mouseDown(f: *Fixture, x: f32, y: f32, clicks: u32, shift: bool) void {
        _ = f.tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = x, .y = y }, .click_count = clicks, .modifiers = .{ .shift = shift } } });
    }

    fn mouseUp(f: *Fixture, x: f32, y: f32) void {
        _ = f.tw.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = x, .y = y } } });
    }

    fn drag(f: *Fixture, x: f32, y: f32) void {
        _ = f.tw.simulateInput(.{ .mouse_move = .{ .position = .{ .x = x, .y = y }, .pressed_button = .left } });
    }

    fn update(f: *Fixture, comptime func: anytype, args: anytype) void {
        _ = f.host().input.update(f.app, func, args);
    }
};

test "typing reaches the editor through the input handler; placeholder layout" {
    var f = try Fixture.init(test_opts, 200);
    defer f.deinit();
    try testing.expect(f.input().display_is_placeholder);
    try testing.expect(f.tw.input_handler != null);
    f.typeChars("héllo 世界");
    try testing.expectEqualStrings("héllo 世界", f.input().text());
    try testing.expect(!f.input().display_is_placeholder);
    try testing.expect(f.host().count(.edited) >= 1);
    // 6 narrow + 2 wide characters at 10/20px.
    try testing.expectApproxEqAbs(@as(f32, 100), f.input().measuredTextWidth(), 0.01);
}

test "keyboard shortcuts: selection, word motion, delete, undo/redo" {
    var f = try Fixture.init(test_opts, 300);
    defer f.deinit();
    f.typeChars("one two three");
    f.key("ctrl-left");
    try testing.expectEqual(@as(usize, 8), f.input().cursorOffset());
    f.key("shift-ctrl-left");
    try testing.expectEqualStrings("two ", f.input().state.selectedText());
    f.key("backspace");
    try testing.expectEqualStrings("one three", f.input().text());
    f.key("ctrl-z");
    try testing.expectEqualStrings("one two three", f.input().text());
    f.key("shift-ctrl-z");
    try testing.expectEqualStrings("one three", f.input().text());
    f.key("ctrl-a");
    try testing.expectEqualStrings("one three", f.input().state.selectedText());
    f.key("home");
    try testing.expectEqual(@as(usize, 0), f.input().cursorOffset());
    f.key("end");
    try testing.expectEqual(@as(usize, 9), f.input().cursorOffset());
    f.key("ctrl-backspace");
    try testing.expectEqualStrings("one ", f.input().text());
    f.key("shift-enter");
    try testing.expectEqualStrings("one \n", f.input().text());
    // Enter submits in the generic Composer context.
    f.key("enter");
    try testing.expectEqual(@as(usize, 1), f.host().count(.submitted));
}

test "soft wrap: hit testing, affinity and vertical motion" {
    // 100px wide: "aaaa bbbb cccc" wraps after "aaaa " and "bbbb ".
    var f = try Fixture.init(test_opts, 100);
    defer f.deinit();
    f.typeChars("aaaaa bbbbb ccccc");
    const in = f.input();
    try testing.expectEqual(@as(usize, 1), in.lines.len);
    try testing.expect(in.lines[0].wrapBoundaries().len >= 1);
    try testing.expectApproxEqAbs(@as(f32, 60), in.content_height, 0.01); // three rows of 20px
    // The boundary offset is both row ends; downstream draws it at the next row start.
    const down = in.pointForIndex(6, .downstream).?;
    try testing.expectEqual(@as(f32, 0), down.x);
    try testing.expectEqual(@as(f32, 20), down.y);
    const upstream = in.pointForIndex(6, .upstream).?;
    try testing.expectEqual(@as(f32, 0), upstream.y);
    // Clicking row 2, column 3 lands on byte 9.
    f.mouseDown(10 + 30, 10 + 25, 1, false);
    f.mouseUp(10 + 30, 10 + 25);
    try testing.expectEqual(@as(usize, 9), f.input().cursorOffset());
    // Up keeps the x column on the row above, down goes to the row below.
    f.key("up");
    try testing.expectEqual(@as(usize, 3), f.input().cursorOffset());
    f.key("down");
    f.key("down");
    try testing.expectEqual(@as(usize, 15), f.input().cursorOffset());
    // Down on the last row goes to the end.
    f.key("down");
    try testing.expectEqual(@as(usize, 17), f.input().cursorOffset());
    // A click past the end of a wrapped row's text lands upstream at its end.
    f.mouseDown(10 + 95, 10 + 5, 1, false);
    f.mouseUp(10 + 95, 10 + 5);
    try testing.expectEqual(ti.CaretAffinity.upstream, f.input().state.affinity);
    try testing.expectEqual(@as(usize, 6), f.input().cursorOffset());
}

test "mouse: double-click word, triple-click line, drag keeps the unit, shift-click extends" {
    var f = try Fixture.init(test_opts, 300);
    defer f.deinit();
    f.typeChars("alpha beta gamma");
    f.mouseDown(10 + 75, 15, 2, false); // inside "beta"
    try testing.expectEqualStrings("beta", f.input().state.selectedText());
    // Dragging right extends word by word.
    f.drag(10 + 125, 15);
    try testing.expectEqualStrings("beta gamma", f.input().state.selectedText());
    f.mouseUp(10 + 125, 15);
    f.mouseDown(10 + 5, 15, 3, false);
    try testing.expectEqualStrings("alpha beta gamma", f.input().state.selectedText());
    f.mouseUp(10 + 5, 15);
    f.mouseDown(10 + 20, 15, 1, false);
    f.mouseUp(10 + 20, 15);
    f.mouseDown(10 + 100, 15, 1, true);
    f.mouseUp(10 + 100, 15);
    try testing.expectEqualStrings("pha beta", f.input().state.selectedText());
    // Plain drag selection.
    f.mouseDown(10 + 0, 15, 1, false);
    f.drag(10 + 50, 15);
    f.mouseUp(10 + 50, 15);
    try testing.expectEqualStrings("alpha", f.input().state.selectedText());
}

test "clipboard: copy / cut / paste through the platform, file URIs become paths" {
    var f = try Fixture.init(test_opts, 300);
    defer f.deinit();
    f.typeChars("copy me");
    f.key("ctrl-a");
    f.key("ctrl-c");
    f.key("end");
    f.key("ctrl-v");
    try testing.expectEqualStrings("copy mecopy me", f.input().text());
    f.key("ctrl-z"); // the paste is its own step
    try testing.expectEqualStrings("copy me", f.input().text());
    f.key("shift-ctrl-left");
    f.key("ctrl-x");
    try testing.expectEqualStrings("copy ", f.input().text());
    try testing.expectEqual(@as(usize, 1), f.host().count(.pasted_text));
    // A file-manager copy pastes as paths for the attachment hook.
    f.app.platform.vtable.writeClipboard(f.app.platform.ptr, "file:///tmp/shot%201.png\nfile:///home/u/a.txt\n");
    f.key("ctrl-v");
    try testing.expectEqualStrings("copy ", f.input().text());
    try testing.expectEqual(@as(usize, 1), f.host().count(.pasted_paths));
    try testing.expectEqual(@as(usize, 2), f.input().pastedPaths().len);
    try testing.expectEqualStrings("/tmp/shot 1.png", f.input().pastedPaths()[0]);
}

test "IME: marked text, UTF-16 ranges, commit and candidate bounds" {
    var f = try Fixture.init(test_opts, 300);
    defer f.deinit();
    f.typeChars("a😀");
    const h = f.tw.input_handler.?;
    h.vtable.replaceAndMarkTextInRange(h.ptr, null, "に", null);
    try testing.expectEqual(@as(usize, 3), h.vtable.markedTextRange(h.ptr).?.start);
    try testing.expectEqual(@as(usize, 4), h.vtable.markedTextRange(h.ptr).?.end);
    h.vtable.replaceAndMarkTextInRange(h.ptr, null, "にほん", .{ .start = 3, .end = 3 });
    const sel = h.vtable.selectedTextRange(h.ptr).?;
    try testing.expectEqual(@as(usize, 6), sel.range.start);
    // The candidate window sits at the caret: 10 + "a" 10 + 😀 20 + 3 × 20 wide = 100.
    const b = h.vtable.boundsForRange(h.ptr, sel.range).?;
    try testing.expectApproxEqAbs(@as(f32, 10 + 10 + 20 + 60), b.origin.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), b.origin.y, 0.01);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = h.vtable.textForRange(h.ptr, .{ .start = 1, .end = 3 }, &out, testing.allocator);
    try testing.expectEqualStrings("😀", out.items);
    h.vtable.replaceTextInRange(h.ptr, h.vtable.markedTextRange(h.ptr), "日本");
    try testing.expectEqualStrings("a😀日本", f.input().text());
    try testing.expect(h.vtable.markedTextRange(h.ptr) == null);
    f.key("ctrl-z");
    try testing.expectEqualStrings("a😀", f.input().text());
    // Unmark commits as typed.
    h.vtable.replaceAndMarkTextInRange(h.ptr, null, "x", null);
    h.vtable.unmarkText(h.ptr);
    try testing.expectEqualStrings("a😀x", f.input().text());
    try testing.expect(h.vtable.markedTextRange(h.ptr) == null);
}

test "overflow: content scrolls to follow the caret; wheel scroll is contained" {
    var f = try Fixture.init(test_opts, 300);
    defer f.deinit();
    f.typeChars("1");
    for (0..5) |_| {
        f.key("shift-enter");
        f.typeChars("x");
    }
    const in = f.input();
    try testing.expectApproxEqAbs(@as(f32, 120), in.content_height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), in.last_bounds.?.size.height, 0.01); // capped
    try testing.expectApproxEqAbs(@as(f32, 60), in.scroll_top, 0.01); // caret on the last row
    _ = f.tw.simulateInput(.{ .scroll_wheel = .{ .position = .{ .x = 20, .y = 20 }, .delta = .{ .pixels = .{ .x = 0, .y = 25 } } } });
    try testing.expectApproxEqAbs(@as(f32, 35), f.input().scroll_top, 0.01);
    f.key("up");
    f.key("up");
    f.key("up");
    f.key("up");
    f.key("up");
    try testing.expectEqual(@as(f32, 0), f.input().scroll_top);
}

test "single-line field: newlines flatten, horizontal reveal" {
    var opts = test_opts;
    opts.single_line = true;
    var f = try Fixture.init(opts, 100);
    defer f.deinit();
    f.update(TextInput.setText, .{"one\ntwo"});
    try testing.expectEqualStrings("one two", f.input().text());
    f.typeChars("abcdefghij");
    const in = f.input();
    try testing.expectEqual(@as(usize, 1), in.lines.len);
    try testing.expectEqual(@as(usize, 0), in.lines[0].wrapBoundaries().len);
    try testing.expect(in.scroll_left > 0);
    try testing.expectApproxEqAbs(in.cursorPoint().?.x - in.scroll_left, 98, 0.01);
    f.key("home");
    try testing.expectEqual(@as(f32, 0), f.input().scroll_left);
    f.key("shift-enter"); // Newline is a no-op in a single-line field
    try testing.expectEqualStrings("one twoabcdefghij", f.input().text());
}

test "caret blinks while focused and stays solid while typing" {
    var f = try Fixture.init(test_opts, 300);
    defer f.deinit();
    f.typeChars("hi");
    try testing.expect(ti.caretVisible(0));
    try testing.expect(ti.caretVisible(499));
    try testing.expect(!ti.caretVisible(500));
    try testing.expect(ti.caretVisible(1000));
    const quads_with_caret = f.w.rendered_frame.scene.quads.items.len;
    f.app.advanceClock(600 * std.time.ns_per_ms);
    try testing.expect(f.w.rendered_frame.scene.quads.items.len < quads_with_caret);
    f.typeChars("!");
    try testing.expectEqual(quads_with_caret, f.w.rendered_frame.scene.quads.items.len);
}

test "pure viewport helpers match Rust" {
    try testing.expectEqual(@as(f32, 0), ti.inputScrollOffsetForCursor(0, 20, 20, 100, 60, null));
    try testing.expectEqual(@as(f32, 20), ti.inputScrollOffsetForCursor(0, 60, 20, 100, 60, null));
    try testing.expectEqual(@as(f32, 40), ti.inputScrollOffsetForCursor(60, 40, 20, 100, 60, null));
    try testing.expectEqual(@as(f32, 0), ti.inputDragScrollDelta(50, 0, 100, 22));
    try testing.expectEqual(@as(f32, -1), ti.inputDragScrollDelta(-2, 0, 100, 22));
    try testing.expectEqual(@as(f32, 22), ti.inputDragScrollDelta(300, 0, 100, 22));
    try testing.expectEqual(@as(f32, 40), ti.inputRevealHeight(50, 0, 20, true));
    try testing.expectEqual(@as(f32, 50), ti.inputRevealHeight(50, 0, 20, false));
    const e = ti.inputOverflowEdges(200, 100, 100, 50);
    try testing.expect(e[0] and e[1]);
    const none = ti.inputOverflowEdges(90, 100, 100, 0);
    try testing.expect(!none[0] and !none[1]);
    try testing.expectEqual(ti.PressIntent.line, ti.pressIntent(3, false));
    try testing.expectEqual(ti.PressIntent.word, ti.pressIntent(2, true));
    try testing.expectEqual(ti.PressIntent.extend_selection, ti.pressIntent(1, true));
}

// ---- dictation (Rust composer_dictation_tests.rs, ComposerInput half) ------------------

const dict = @import("dictation.zig");

/// A scripted transcriber; the test owns it (drops count `deinit`s).
const FakeTranscriber = struct {
    events: [16]dict.Event = undefined,
    len: usize = 0,
    head: usize = 0,
    finishes: usize = 0,
    drops: usize = 0,

    const vtable: dict.Transcriber.VTable = .{ .poll = poll, .finish = finish, .level = level, .deinit = drop };

    fn transcriber(self: *FakeTranscriber) dict.Transcriber {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn push(self: *FakeTranscriber, evs: []const dict.Event) void {
        for (evs) |e| {
            self.events[self.len] = e;
            self.len += 1;
        }
    }
    fn poll(ctx: *anyopaque) ?dict.Event {
        const self: *FakeTranscriber = @ptrCast(@alignCast(ctx));
        if (self.head == self.len) return null;
        self.head += 1;
        return self.events[self.head - 1];
    }
    fn finish(ctx: *anyopaque) void {
        const self: *FakeTranscriber = @ptrCast(@alignCast(ctx));
        self.finishes += 1;
    }
    fn level(_: *anyopaque) f32 {
        return 0.05;
    }
    fn drop(ctx: *anyopaque) void {
        const self: *FakeTranscriber = @ptrCast(@alignCast(ctx));
        self.drops += 1;
    }
};

const DictOps = struct {
    fn begin(in: *TextInput, fake: *FakeTranscriber, cx: *Context(TextInput)) void {
        in.beginDictation(fake.transcriber(), cx);
    }
    fn poll(in: *TextInput, cx: *Context(TextInput)) bool {
        return in.pollDictation(in.dictation.generation, cx);
    }
    fn pollGen(in: *TextInput, generation: u64, cx: *Context(TextInput)) bool {
        return in.pollDictation(generation, cx);
    }
    fn finish(in: *TextInput, send: bool, cx: *Context(TextInput)) bool {
        return in.finishDictation(send, cx);
    }
    fn select(in: *TextInput, start: usize, end: usize, _: *Context(TextInput)) void {
        in.state.selectRange(.{ .start = start, .end = end });
    }
};

fn dictFixture() !Fixture {
    var opts = test_opts;
    opts.key_context = actions.keymap.message_composer_context;
    return Fixture.init(opts, 300);
}

fn deliver(f: *Fixture, fake: *FakeTranscriber, evs: []const dict.Event) bool {
    fake.push(evs);
    return f.host().input.update(f.app, DictOps.poll, .{});
}

test "dictation replaces a unicode selection and undoes as one edit" {
    var f = try dictFixture();
    defer f.deinit();
    f.update(TextInput.setText, .{"👩🏽‍💻 replace café"});
    const begin = std.mem.indexOf(u8, f.input().text(), "replace").?;
    f.update(DictOps.select, .{ begin, begin + "replace".len });
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{ .listening, .{ .partial = "你好" }, .{ .partial = "bonjour 🌍" } });
    try testing.expectEqualStrings("👩🏽‍💻 bonjour 🌍 café", f.input().text());
    try testing.expectEqual(@as(usize, 1), f.input().state.undo_stack.items.len);
    try testing.expect(f.input().dictation.phase == .listening);
    _ = f.host().input.update(f.app, DictOps.finish, .{false});
    _ = deliver(&f, &fake, &.{.{ .final = "salut 🌍" }});
    try testing.expectEqualStrings("👩🏽‍💻 salut 🌍 café", f.input().text());
    try testing.expectEqual(@as(usize, 1), fake.drops);
    f.key("ctrl-z");
    try testing.expectEqualStrings("👩🏽‍💻 replace café", f.input().text());
    try testing.expect(f.input().state.selected.eql(.{ .start = begin, .end = begin + 7 }));
    f.key("shift-ctrl-z");
    try testing.expectEqualStrings("👩🏽‍💻 salut 🌍 café", f.input().text());
}

test "dictation: a manual edit stops it before replacing the partial" {
    var f = try dictFixture();
    defer f.deinit();
    f.update(TextInput.setText, .{"before after"});
    f.update(DictOps.select, .{ 7, 7 });
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    const old = f.input().dictation.generation;
    _ = deliver(&f, &fake, &.{.{ .partial = "speech " }});
    try testing.expectEqualStrings("before speech after", f.input().text());
    f.update(TextInput.replaceRange, .{ 7, 13, "typed" });
    try testing.expectEqualStrings("before typed after", f.input().text());
    try testing.expectEqual(@as(usize, 1), fake.drops);
    fake.push(&.{.{ .final = "stale" }});
    try testing.expect(!f.host().input.update(f.app, DictOps.pollGen, .{old}));
    try testing.expectEqualStrings("before typed after", f.input().text());
    f.key("ctrl-z");
    try testing.expectEqualStrings("before speech after", f.input().text());
    f.key("ctrl-z");
    try testing.expectEqualStrings("before after", f.input().text());
}

test "dictation: IME composition cancels it and keeps history" {
    var f = try dictFixture();
    defer f.deinit();
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{.{ .partial = "Hello " }});
    const h = f.tw.input_handler.?;
    h.vtable.replaceAndMarkTextInRange(h.ptr, null, "に", null);
    try testing.expectEqual(@as(usize, 1), fake.drops);
    h.vtable.replaceAndMarkTextInRange(h.ptr, null, "日本", null);
    h.vtable.replaceTextInRange(h.ptr, null, "日本語");
    try testing.expectEqualStrings("Hello 日本語", f.input().text());
    f.key("ctrl-z");
    try testing.expectEqualStrings("Hello ", f.input().text());
    f.key("ctrl-z");
    try testing.expectEqualStrings("", f.input().text());
}

test "dictation: moving the selection or undo while waiting cancels it" {
    var f = try dictFixture();
    defer f.deinit();
    f.update(TextInput.setText, .{"draft"});
    var first: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&first});
    f.key("ctrl-z"); // No history is still a deliberate cancellation.
    try testing.expectEqual(@as(usize, 1), first.drops);
    var second: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&second});
    _ = deliver(&f, &second, &.{.{ .partial = " words" }});
    f.key("home");
    try testing.expectEqual(@as(usize, 1), second.drops);
    try testing.expectEqualStrings("draft words", f.input().text());
    try testing.expect(f.input().state.selected.eql(.collapsed(0)));
}

test "dictation: send finalizes once and keeps the latest final" {
    var f = try dictFixture();
    defer f.deinit();
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{ .listening, .{ .partial = "hel" } });
    try testing.expect(f.host().input.update(f.app, DictOps.finish, .{true}));
    try testing.expect(f.host().input.update(f.app, DictOps.finish, .{true}));
    try testing.expect(f.host().input.update(f.app, DictOps.finish, .{false}));
    try testing.expectEqual(@as(usize, 1), fake.finishes);
    _ = deliver(&f, &fake, &.{ .{ .final = "hello" }, .{ .final = "duplicate" } });
    try testing.expectEqualStrings("hello", f.input().text());
    try testing.expect(f.input().dictation.phase == .idle);
    try testing.expectEqual(@as(usize, 1), fake.drops);
    try testing.expectEqual(@as(usize, 1), f.host().count(.dictation_submit));
}

test "dictation: failure cancels the send; retries preserve the draft" {
    var f = try dictFixture();
    defer f.deinit();
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{.{ .partial = "keep me" }});
    _ = f.host().input.update(f.app, DictOps.finish, .{true});
    _ = deliver(&f, &fake, &.{.{ .failed = "Disconnected" }});
    try testing.expectEqualStrings("keep me", f.input().text());
    try testing.expectEqualStrings("Disconnected", f.input().dictation.phase.failed);
    try testing.expectEqual(@as(usize, 1), fake.drops);
    for ([_]dict.Event{ .{ .denied = "Permission denied" }, .{ .unavailable = "Locale unavailable" } }) |err| {
        var retry: FakeTranscriber = .{};
        f.update(DictOps.begin, .{&retry});
        _ = deliver(&f, &retry, &.{err});
        try testing.expectEqualStrings("keep me", f.input().text());
        try testing.expect(!f.input().dictation.phase.active());
        try testing.expectEqual(@as(usize, 1), retry.drops);
    }
    var again: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&again});
    _ = deliver(&f, &again, &.{ .{ .partial = " again" }, .{ .final = " again" } });
    try testing.expectEqualStrings("keep me again", f.input().text());
    try testing.expectEqual(@as(usize, 0), f.host().count(.dictation_submit));
}

test "dictation: an empty final keeps the selection or the latest partial" {
    var f = try dictFixture();
    defer f.deinit();
    for ([_]?[]const u8{ null, "replacement" }) |partial| {
        f.update(TextInput.setText, .{"selected"});
        f.update(DictOps.select, .{ 0, 8 });
        var fake: FakeTranscriber = .{};
        f.update(DictOps.begin, .{&fake});
        if (partial) |p| _ = deliver(&f, &fake, &.{.{ .partial = p }});
        _ = f.host().input.update(f.app, DictOps.finish, .{false});
        _ = deliver(&f, &fake, &.{.{ .final = "" }});
        try testing.expectEqualStrings(partial orelse "selected", f.input().text());
        try testing.expectEqual(@as(usize, @intFromBool(partial != null)), f.input().state.undo_stack.items.len);
        // Silence with nothing written explains itself.
        if (partial == null) try testing.expect(f.input().dictation.phase == .no_speech);
    }
}

test "dictation: a draft swap invalidates finalization and stale results" {
    var f = try dictFixture();
    defer f.deinit();
    for ([_]bool{ false, true }) |finalizing| {
        f.update(TextInput.setText, .{"original"});
        var fake: FakeTranscriber = .{};
        f.update(DictOps.begin, .{&fake});
        const generation = f.input().dictation.generation;
        if (finalizing) _ = f.host().input.update(f.app, DictOps.finish, .{true});
        f.update(TextInput.setText, .{"different chat / queued draft"});
        fake.push(&.{ .listening, .{ .final = "late" } });
        try testing.expect(!f.host().input.update(f.app, DictOps.pollGen, .{generation}));
        try testing.expectEqual(@as(usize, 1), fake.drops);
        try testing.expectEqualStrings("different chat / queued draft", f.input().text());
        try testing.expectEqual(@as(usize, 0), f.input().state.undo_stack.items.len);
    }
    try testing.expectEqual(@as(usize, 0), f.host().count(.dictation_submit));
}

test "dictation: cancelled native capture drops the pending send" {
    var f = try dictFixture();
    defer f.deinit();
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{.{ .partial = "keep draft" }});
    _ = f.host().input.update(f.app, DictOps.finish, .{true});
    _ = deliver(&f, &fake, &.{.cancelled});
    try testing.expectEqual(@as(usize, 1), fake.drops);
    try testing.expectEqualStrings("keep draft", f.input().text());
    try testing.expect(f.input().dictation.phase == .idle);
    try testing.expectEqual(@as(usize, 0), f.host().count(.dictation_submit));
}

test "dictation: the finalize deadline keeps the latest partial without sending" {
    var f = try dictFixture();
    defer f.deinit();
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{ .listening, .{ .partial = "latest" } });
    _ = f.host().input.update(f.app, DictOps.finish, .{true});
    // The 40 ms poll keeps running on the app clock; nothing answers.
    f.app.advanceClock(dict.finalize_timeout_ns + 100 * std.time.ns_per_ms);
    try testing.expectEqualStrings("latest", f.input().text());
    try testing.expectEqual(@as(usize, 1), fake.drops);
    try testing.expect(f.input().dictation.phase == .failed);
    try testing.expectEqual(@as(usize, 0), f.host().count(.dictation_submit));
}

test "dictation: Escape cancels and keeps what was written; releasing the input releases the microphone" {
    var f = try dictFixture();
    var fake: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&fake});
    _ = deliver(&f, &fake, &.{.{ .partial = "spoken" }});
    f.key("escape");
    try testing.expectEqual(@as(usize, 1), fake.drops);
    try testing.expect(f.input().dictation.phase == .idle);
    try testing.expectEqualStrings("spoken", f.input().text());
    var live: FakeTranscriber = .{};
    f.update(DictOps.begin, .{&live});
    f.deinit();
    try testing.expectEqual(@as(usize, 1), live.drops);
}

fn fakeEnabled(_: ?*anyopaque, _: *App) bool {
    return true;
}
fn fakeStart(_: ?*anyopaque, _: *App) ?dict.Transcriber {
    return null;
}
fn fakePending(_: ?*anyopaque) bool {
    return false;
}
fn fakeBinding(_: ?*anyopaque, _: *App, buf: []u8) []const u8 {
    const combo = if (@import("builtin").os.tag == .macos) "cmd-d" else "ctrl-d";
    @memcpy(buf[0..combo.len], combo);
    return buf[0..combo.len];
}

test "dictation shortcut: held until its key or modifier is released" {
    var f = try dictFixture();
    defer f.deinit();
    // Off (no service): the chord does nothing here.
    f.key("ctrl-d");
    try testing.expectEqual(@as(usize, 0), f.host().count(.dictation_press));
    try f.app.setGlobal(dict.Service{ .enabled = fakeEnabled, .start = fakeStart, .permission_pending = fakePending, .binding = fakeBinding });
    const mod: zpui.input.Modifiers = if (@import("builtin").os.tag == .macos) .{ .platform = true } else .{ .control = true };
    _ = f.tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "d", .modifiers = mod } } });
    // Auto-repeat while held is ignored.
    _ = f.tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "d", .modifiers = mod }, .is_held = true } });
    try testing.expectEqual(@as(usize, 1), f.host().count(.dictation_press));
    // Another key coming up is not the release.
    _ = f.tw.simulateInput(.{ .key_up = .{ .keystroke = .{ .key = "x" } } });
    try testing.expectEqual(@as(usize, 0), f.host().count(.dictation_release));
    // macOS sends no key-up for Command chords: letting go of the modifier releases.
    _ = f.tw.simulateInput(.{ .modifiers_changed = .{ .modifiers = .{} } });
    try testing.expectEqual(@as(usize, 1), f.host().count(.dictation_release));
    _ = f.tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "d", .modifiers = mod } } });
    _ = f.tw.simulateInput(.{ .key_up = .{ .keystroke = .{ .key = "d", .modifiers = mod } } });
    try testing.expectEqual(@as(usize, 2), f.host().count(.dictation_press));
    try testing.expectEqual(@as(usize, 2), f.host().count(.dictation_release));
}
