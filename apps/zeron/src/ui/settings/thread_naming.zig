//! Settings → General → Thread naming (zeron `settings/thread_naming.rs` +
//! the title-bound model picker): which agent and model title new threads,
//! loaded with `GetTitleSettings` and saved with `SetTitleSettings` (either
//! reply is the device's authoritative settings). "Session agent" means
//! each thread is named by its own agent; otherwise a title-capable agent's
//! model (Claude Code, Codex) is picked from the dropdown. Reset returns to
//! the session agent.
//!
//! ```zig
//! thread_naming.ensureLoaded(view, cx);   // on render of the General page
//! row.child(thread_naming.control(view, theme, cx));
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const ui = @import("../components/root.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Context = zpui.Context;
const Theme = ui.Theme;
const protocol = engine.protocol;
const HarnessId = protocol.HarnessId;
const div = zpui.div;
const px = zpui.px;

/// `zeron_engine::registry::TitleSettings`.
pub const TitleSettings = struct {
    /// null follows the session harness.
    harness: ?HarnessId = null,
    /// null selects the cheapest model offered by the harness.
    model: ?[]const u8 = null,
};

pub const State = struct {
    phase: enum { idle, loading, ready, failed } = .idle,
    value: ?std.json.Parsed(TitleSettings) = null,
    /// A failed save (shown under the row) or load (shown in place).
    err: ?[]u8 = null,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.value) |*p| p.deinit();
        if (self.err) |e| gpa.free(e);
    }

    pub fn settings(self: *const State) TitleSettings {
        return if (self.value) |p| p.value else .{};
    }
};

/// `zeron_harness::supports_titles` (Mock excluded from the picker).
pub fn supportsTitles(h: HarnessId) bool {
    return h == .codex or h == .@"claude-code";
}

fn engineOf(v: *SettingsView, cx: anytype) zpui.Entity(model.EngineState) {
    return v.state.read(cx).catalog.read(cx).engine;
}

fn setErr(v: *SettingsView, msg: []const u8) void {
    if (v.title.err) |e| v.gpa.free(e);
    v.title.err = v.gpa.dupe(u8, msg) catch null;
}

/// `call(None)`: load once (again after a failed load when the engine is back).
pub fn ensureLoaded(v: *SettingsView, cx: *Context(SettingsView)) void {
    if (v.title.phase != .idle) return;
    call(v, null, cx);
}

/// `GetTitleSettings`, or `SetTitleSettings` when saving.
pub fn call(v: *SettingsView, save: ?TitleSettings, cx: *Context(SettingsView)) void {
    if (v.title.phase == .idle) v.title.phase = .loading;
    const eng = engineOf(v, cx);
    const res = if (save) |s|
        model.EngineState.request(eng, cx, SettingsView, cx.entityId(), .SetTitleSettings, s, onReply)
    else
        model.EngineState.request(eng, cx, SettingsView, cx.entityId(), .GetTitleSettings, {}, onReply);
    res catch |err| {
        if (err == error.NotConnected) {
            // No engine (yet): show the default choice; the next open retries.
            if (v.title.phase == .loading) v.title.phase = .idle;
        } else setErr(v, @errorName(err));
    };
    cx.notify();
}

fn onReply(v: *SettingsView, result: model.engine_state.CallResult, cx: *Context(SettingsView)) void {
    switch (result) {
        .ok => |val| {
            const parsed = std.json.parseFromValue(TitleSettings, v.gpa, val, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                return failed(v, @errorName(err), cx);
            };
            if (v.title.value) |*p| p.deinit();
            v.title.value = parsed;
            v.title.phase = .ready;
            if (v.title.err) |e| v.gpa.free(e);
            v.title.err = null;
        },
        .err => |e| return failed(v, e.message, cx),
    }
    cx.notify();
}

fn failed(v: *SettingsView, msg: []const u8, cx: *Context(SettingsView)) void {
    setErr(v, msg);
    if (v.title.phase != .ready) v.title.phase = .failed;
    cx.notify();
}

// ---- the dropdown ------------------------------------------------------------------

/// One row: "Session agent" (harness null) or a title-capable agent's model.
pub const Choice = struct { harness: ?HarnessId, model: ?[]const u8, label: []const u8 };

/// Title-capable, enabled + installed harnesses, then their models (`ListModels`).
pub fn choices(v: *SettingsView, a: std.mem.Allocator, cx: anytype) []const Choice {
    var out: std.ArrayList(Choice) = .empty;
    out.append(a, .{ .harness = null, .model = null, .label = "Session agent" }) catch {};
    const cat = v.state.read(cx).catalog.read(cx);
    for (cat.harnessList()) |d| {
        if (!supportsTitles(d.id) or !d.installed or !(d.enabled orelse true)) continue;
        const models = cat.modelList(d.id) orelse continue;
        for (models) |m| out.append(a, .{ .harness = d.id, .model = m.id, .label = m.label }) catch {};
    }
    return out.items;
}

/// The saved choice's index in `list` (0 = Session agent).
pub fn selectedIndex(list: []const Choice, s: TitleSettings) usize {
    const h = s.harness orelse return 0;
    for (list, 0..) |c, i| if (c.harness == h) {
        if (s.model == null or (c.model != null and std.mem.eql(u8, c.model.?, s.model.?))) return i;
    };
    return 0;
}

/// Load model lists for the title-capable agents (menu open).
pub fn loadModels(v: *SettingsView, cx: anytype) void {
    const catalog = v.state.read(cx).catalog;
    const list = catalog.read(cx).harnessList();
    var ids: [8]HarnessId = undefined;
    var n: usize = 0;
    for (list) |d| if (supportsTitles(d.id) and n < ids.len) {
        ids[n] = d.id;
        n += 1;
    };
    for (ids[0..n]) |h| catalog.update(cx, model.CatalogStore.loadModels, .{ h, false });
}

/// Apply row `ix` (`pick_model` in title mode / Reset for row 0).
pub fn commit(v: *SettingsView, ix: usize, cx: *Context(SettingsView)) void {
    const a = zpui.window.arena_mod.frameAllocator();
    const list = choices(v, a, cx);
    if (ix >= list.len) return;
    const c = list[ix];
    call(v, .{ .harness = c.harness, .model = c.model }, cx);
}

/// The chip's label (`model_label` in title mode).
pub fn chipLabel(v: *SettingsView, cx: anytype) []const u8 {
    const s = v.title.settings();
    const h = s.harness orelse return "Session agent";
    const id = s.model orelse return "Automatic";
    if (v.state.read(cx).catalog.read(cx).modelList(h)) |models| for (models) |m| {
        if (std.mem.eql(u8, m.id, id)) return m.label;
    };
    return id;
}

fn onReset(v: *SettingsView, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *Context(SettingsView)) void {
    call(v, .{}, cx);
}

/// Reset (when not following the session) + the picker chip, or the load state.
pub fn control(v: *SettingsView, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    if (v.title.phase == .failed) return div().textColor(t.text_muted).child(v.title.err orelse "Unavailable");
    if (v.title.phase == .loading and v.title.value == null) return div().textColor(t.text_muted).child("Loading…");
    const s = v.title.settings();
    var row = div().flexNone().flex().flexRow().itemsCenter().gap(px(4));
    if (s.harness != null) row = row.child(w.textAction(t, .quiet, "Reset").id("thread-naming-reset").onClick(cx.listener(onReset)));
    return row.child(chip(v, t, cx));
}

pub fn description(v: *const SettingsView) []const u8 {
    return if (v.title.settings().harness == null) "Each thread is named by its own agent." else "A small model keeps titles fast and cheap.";
}

fn chip(v: *SettingsView, t: *const Theme, cx: *Context(SettingsView)) zpui.StatefulDiv {
    const open = v.open_select == .thread_naming;
    const key = select.hoverKey(.thread_naming);
    const bg = if (open) t.glassHover() else ui.hover.blend(cx, key, t.glassHover().opacity(0), t.glassHover());
    const s = v.title.settings();
    const icon_el = if (s.harness) |h| blk: {
        const mark, const tint = ui.icon.harnessMark(h);
        break :blk ui.icon.of(mark, 16, tint orelse t.text_muted);
    } else ui.icon.of(.chat_round_line, 16, t.text_muted);
    var c = div().id("thread-naming-picker").relative().flexNone().h(px(28)).px(px(6)).rounded(px(8))
        .flex().flexRow().itemsCenter().gap(px(6)).cursorPointer().bg(bg)
        .textSize(ui.rems(12.5)).textColor(t.text)
        .onHover(cx.listenerWith(select.SelectId.thread_naming, SettingsView.onSelectHover))
        .onClick(cx.listenerWith(select.SelectId.thread_naming, SettingsView.onSelectTrigger))
        .child(icon_el)
        .child(chipLabel(v, cx));
    if (open) c = c.child(select.menuFor(v, .thread_naming, t, cx));
    return c;
}

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "the saved title choice maps to its dropdown row" {
    const list = [_]Choice{
        .{ .harness = null, .model = null, .label = "Session agent" },
        .{ .harness = .@"claude-code", .model = "haiku", .label = "Haiku" },
        .{ .harness = .@"claude-code", .model = "sonnet", .label = "Sonnet" },
        .{ .harness = .codex, .model = "mini", .label = "Mini" },
    };
    try testing.expectEqual(@as(usize, 0), selectedIndex(&list, .{}));
    try testing.expectEqual(@as(usize, 2), selectedIndex(&list, .{ .harness = .@"claude-code", .model = "sonnet" }));
    try testing.expectEqual(@as(usize, 3), selectedIndex(&list, .{ .harness = .codex }));
    try testing.expect(supportsTitles(.codex) and !supportsTitles(.pi) and !supportsTitles(.mock));
}
