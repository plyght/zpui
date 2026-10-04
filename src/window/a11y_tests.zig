//! Accessibility tree tests on the headless TestPlatform (src/a11y.zig, Window a11y API).

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const Entity = @import("../app/entity.zig").Entity;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const StyleBuilder = @import("../styled.zig").StyleBuilder;
const geometry = @import("../geometry.zig");
const events = @import("events.zig");
const FocusHandle = @import("focus.zig").FocusHandle;
const a11y = @import("../a11y.zig");

const px = geometry.px;
const sb = StyleBuilder.init;
const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };

fn dump(tree: *const a11y.Tree) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try tree.dump(&out.writer);
    return out.toOwnedSlice();
}

fn expectDump(tree: *const a11y.Tree, expected: []const u8) !void {
    const got = try dump(tree);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("--- tree ---\n{s}\n", .{got});
        return e;
    };
}

fn activate(w: *Window) *TestWindow {
    const tw = TestWindow.of(w.platform_window);
    tw.simulateA11yActivation(true);
    tw.frame(false);
    return tw;
}

const Settings = struct {
    clicks: u32 = 0,
    enabled: bool = false,
    query: []const u8 = "",
    set_value: [32]u8 = undefined,
    set_value_len: usize = 0,
    focus: FocusHandle,
    list_focus: FocusHandle,
    selected: usize = 1,

    fn init(_: *Window, cx: *Context(Settings)) Settings {
        return .{ .focus = cx.focusHandle(), .list_focus = cx.focusHandle() };
    }
    pub fn deinit(self: *Settings, cx: *App) void {
        self.focus.release(cx);
        self.list_focus.release(cx);
    }

    pub fn render(self: *Settings, _: *Window, cx: *Context(Settings)) elements.Div {
        var list = div().id("models").role(.list_box).ariaLabel("Models").trackFocus(self.list_focus).flex().flexCol();
        for ([_][]const u8{ "Opus", "Sonnet", "Haiku" }, 0..) |m, ix| {
            var opt = div().id(.{ "model", ix }).role(.list_box_option).ariaSelected(ix == self.selected).h(px(20)).child(m);
            if (ix == self.selected) opt = opt.ariaActiveDescendant();
            list = list.child(opt);
        }
        return div().size(px(400)).flex().flexCol()
            .child(div().id("page").role(.group).ariaLabel("Settings").flex().flexCol()
                .child("General")
                .child(div().id("save").role(.button).w(px(80)).h(px(30)).child("Save changes")
                    .onClick(cx.listener(Settings.onSave)))
                .child(div().id("sync").role(.@"switch").ariaLabel("Sync").ariaToggled(self.enabled).h(px(20))
                    .trackFocus(self.focus))
                .child(div().id("search").role(.search_input).ariaPlaceholder("Search").ariaValue(self.query).h(px(20))
                    .onA11yAction(.set_value, cx.listener(Settings.onSetValue)))
                .child(div().id("hidden").role(.button).ariaLabel("Hidden").hidden()))
            .child(list);
    }

    fn onSave(self: *Settings, _: *const events.ClickEvent, _: *Window, cx: *Context(Settings)) void {
        self.clicks += 1;
        cx.notify();
    }

    fn onSetValue(self: *Settings, req: *const a11y.ActionRequest, _: *Window, cx: *Context(Settings)) void {
        const v = req.value orelse return;
        @memcpy(self.set_value[0..v.len], v);
        self.set_value_len = v.len;
        self.query = self.set_value[0..v.len];
        cx.notify();
    }

    fn toggle(self: *Settings, cx: *Context(Settings)) void {
        self.enabled = !self.enabled;
        cx.notify();
    }
};

test "no tree is built until assistive technology activates the window" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Settings, Settings.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    try testing.expectEqual(@as(u32, 0), tw.a11y_update_count);
    try testing.expect(!w.a11yActive());
    _ = activate(w);
    try testing.expect(w.a11yActive());
    try testing.expectEqual(@as(u32, 1), tw.a11y_update_count);
    try testing.expect(tw.a11yTree().? == w.a11yTree());
    try testing.expect(w.a11yChanges().full);

    // Deactivation stops updates.
    tw.simulateA11yActivation(false);
    tw.frame(false);
    try testing.expectEqual(@as(u32, 1), tw.a11y_update_count);
}

test "roles, labels, text content, states and placeholders form the tree" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Settings, Settings.init, .{});
    const w = handle.window(app).?;
    w.setTitle("Zeron");
    const tw = activate(w);
    try expectDump(tw.a11yTree().?,
        \\window "Zeron"
        \\  group "Settings"
        \\    label "General"
        \\    button "Save changes"
        \\    switch "Sync" toggled=off
        \\    search_input value="" placeholder="Search"
        \\  list_box "Models"
        \\    list_box_option "Opus"
        \\    list_box_option "Sonnet" selected
        \\    list_box_option "Haiku"
        \\
    );
    const tree = w.a11yTree();
    const save = findRole(tree, .button, 0);
    try testing.expect(save.actions.contains(.click));
    try testing.expect(save.bounds.size.width == 80 and save.bounds.size.height == 30);
    try testing.expect(findRole(tree, .@"switch", 0).actions.contains(.focus));
}

fn findRole(tree: *const a11y.Tree, role: a11y.Role, nth: usize) *const a11y.Node {
    var k: usize = 0;
    for (tree.nodes.items) |*n| if (n.role == role) {
        if (k == nth) return n;
        k += 1;
    };
    @panic("role not found");
}

test "press, focus and set-value requests reach the element" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Settings, Settings.init, .{});
    const w = handle.window(app).?;
    const root = handle.rootView(app).?;
    const tw = activate(w);

    // Press: synthesized click at the node's center.
    tw.simulateA11yAction(.{ .target = findRole(w.a11yTree(), .button, 0).id, .action = .click });
    try testing.expectEqual(@as(u32, 1), root.read(app).clicks);

    // Focus: moves keyboard focus to the node's handle; the next tree reports it.
    const sw = findRole(w.a11yTree(), .@"switch", 0).id;
    tw.simulateA11yAction(.{ .target = sw, .action = .focus });
    try testing.expect(root.read(app).focus.isFocused(w));
    tw.frame(false);
    try testing.expectEqual(sw, w.a11yTree().focusId());
    try testing.expect(w.a11yChanges().focus_changed);

    // Set value: the element's onA11yAction listener.
    tw.simulateA11yAction(.{ .target = findRole(w.a11yTree(), .search_input, 0).id, .action = .set_value, .value = "opus" });
    tw.frame(false);
    try testing.expectEqualStrings("opus", root.read(app).query);
    const search = findRole(w.a11yTree(), .search_input, 0);
    try testing.expectEqualStrings("opus", w.a11yTree().str(search.value).?);
    try testing.expect(w.a11yChanges().find(search.id).?.value);

    // Blur.
    tw.simulateA11yAction(.{ .target = sw, .action = .blur });
    try testing.expect(!root.read(app).focus.isFocused(w));
}

test "incremental updates report only what changed" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Settings, Settings.init, .{});
    const w = handle.window(app).?;
    const root = handle.rootView(app).?;
    const tw = activate(w);
    const count = tw.a11y_update_count;
    root.update(app, Settings.toggle, .{});
    tw.frame(false);
    try testing.expectEqual(count + 1, tw.a11y_update_count);
    const ch = w.a11yChanges();
    try testing.expect(!ch.full);
    try testing.expectEqual(@as(usize, 1), ch.entries.items.len);
    const e = ch.entries.items[0];
    try testing.expect(e.what.state);
    try testing.expectEqual(a11y.Toggled.off, e.was_toggled.?);
    try testing.expectEqual(a11y.Toggled.on, w.a11yTree().get(e.id).?.toggled.?);
}

test "active descendant is reported while the list box holds focus" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Settings, Settings.init, .{});
    const w = handle.window(app).?;
    const root = handle.rootView(app).?;
    const tw = activate(w);
    try testing.expectEqual(a11y.NodeId.root, w.a11yTree().focusId());
    w.focus(root.read(app).list_focus);
    tw.frame(false);
    const sonnet = findRole(w.a11yTree(), .list_box_option, 1);
    try testing.expectEqual(sonnet.id, w.a11yTree().focusId());
}

// ---- cached views keep their nodes -----------------------------------------------------------

const Leaf = struct {
    label: []const u8,
    renders: u32 = 0,
    pub fn render(self: *Leaf, _: *Window, _: *Context(Leaf)) elements.StatefulDiv {
        self.renders += 1;
        return div().id("leaf").role(.button).h(px(20)).child(self.label);
    }
    fn setLabel(self: *Leaf, label: []const u8, cx: *Context(Leaf)) void {
        self.label = label;
        cx.notify();
    }
};

const Shell = struct {
    left: Entity(Leaf),
    right: Entity(Leaf),
    fn init(_: *Window, cx: *Context(Shell)) !Shell {
        return .{ .left = try cx.new(Leaf, .{ .label = "Left" }), .right = try cx.new(Leaf, .{ .label = "Right" }) };
    }
    pub fn deinit(self: *Shell, cx: *App) void {
        self.left.release(cx);
        self.right.release(cx);
    }
    pub fn render(self: *Shell, _: *Window, _: *Context(Shell)) elements.StatefulDiv {
        const full = sb.wFull().h(px(20)).refinement;
        return div().id("shell").role(.toolbar).flex().flexCol()
            .child(self.left.cached(full))
            .child(self.right.cached(full));
    }
};

test "cached views reuse their accessibility subtree" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Shell, Shell.init, .{});
    const w = handle.window(app).?;
    const shell = handle.rootView(app).?;
    const tw = activate(w);
    const expected =
        \\window
        \\  toolbar
        \\    button "Left"
        \\    button "Right"
        \\
    ;
    try expectDump(tw.a11yTree().?, expected);
    const right = shell.read(app).right;
    const renders = right.read(app).renders;
    shell.read(app).left.update(app, Leaf.setLabel, .{"Left!"});
    tw.frame(false);
    try testing.expectEqual(renders, right.read(app).renders); // reused, not re-rendered
    try expectDump(tw.a11yTree().?,
        \\window
        \\  toolbar
        \\    button "Left!"
        \\    button "Right"
        \\
    );
    // Only the left button's name changed.
    const ch = w.a11yChanges();
    try testing.expectEqual(@as(usize, 1), ch.entries.items.len);
    try testing.expect(ch.entries.items[0].what.name);
}
