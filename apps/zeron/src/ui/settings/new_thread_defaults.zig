//! Settings → General → New threads (Zig client addition; the Rust app only
//! has the composer's sticky "last used" memory): a "Default agent" and a
//! "Default model" select. Each offers "Last used" (the Rust behaviour, and
//! the default) followed by the installed + enabled agents and the chosen
//! agent's models (the same `CatalogStore` lists the composer's model picker
//! reads). Stored in `new-thread-defaults.json` via `model.composer_store`;
//! the composer's new-thread resolution (`run_config.effectiveHarness` /
//! `effectiveModelId`) reads it and falls back to last used, then to the
//! first offered agent, when the default is unavailable.
//!
//! ```zig
//! page.child(new_thread_defaults.card(view, theme, cx));
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const rc = @import("zeron_composer").run_config;
const ui = @import("../components/root.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Context = zpui.Context;
const Theme = ui.Theme;
const protocol = engine.protocol;
const HarnessId = protocol.HarnessId;
const composer_store = model.composer_store;
const NewThreadDefaults = composer_store.NewThreadDefaults;
const div = zpui.div;
const px = zpui.px;

pub const last_used = "Last used";
const unavailable = "unavailable";

fn appOf(cx: anytype) *zpui.App {
    return if (@TypeOf(cx) == *zpui.App) cx else cx.app;
}

/// The stored defaults ("Last used" for both when nothing is stored).
pub fn current(cx: anytype) NewThreadDefaults {
    return if (composer_store.preferred(appOf(cx))) |p| p.* else .{};
}

/// One "Default agent" row: null = Last used.
pub const AgentChoice = struct { harness: ?HarnessId, label: []const u8, available: bool = true };
/// One "Default model" row: null = Last used.
pub const ModelChoice = struct { id: ?[]const u8, label: []const u8, available: bool = true };

/// "Last used", the offered agents (installed + enabled; Mock only when it
/// is all there is), then a stored agent that is no longer offered.
pub fn agentChoices(a: std.mem.Allocator, harnesses: []const protocol.HarnessDescriptor, stored: NewThreadDefaults) []const AgentChoice {
    var out: std.ArrayList(AgentChoice) = .empty;
    out.append(a, .{ .harness = null, .label = last_used }) catch {};
    var buf: [16]protocol.HarnessDescriptor = undefined;
    var found = stored.harness == null;
    for (rc.offeredHarnesses(harnesses, false, &buf)) |d| {
        if (stored.harness == d.id) found = true;
        out.append(a, .{ .harness = d.id, .label = d.name }) catch {};
    }
    if (!found) {
        const h = stored.harness.?;
        var name: []const u8 = @tagName(h);
        for (harnesses) |d| if (d.id == h) {
            name = d.name;
        };
        out.append(a, .{ .harness = h, .label = name, .available = false }) catch {};
    }
    return out.items;
}

/// "Last used", then the default agent's models (once loaded), then a
/// stored model the list doesn't (or doesn't yet) contain.
pub fn modelChoices(a: std.mem.Allocator, models: ?[]const protocol.Model, stored: NewThreadDefaults) []const ModelChoice {
    var out: std.ArrayList(ModelChoice) = .empty;
    out.append(a, .{ .id = null, .label = last_used }) catch {};
    var found = stored.model == null;
    if (models) |list| for (list) |m| {
        if (stored.model) |s| if (std.mem.eql(u8, s.id, m.id)) {
            found = true;
        };
        out.append(a, .{ .id = m.id, .label = m.label }) catch {};
    };
    if (!found) {
        const s = stored.model.?;
        // Still loading: the stored label is the row; loaded without it: gone.
        out.append(a, .{ .id = s.id, .label = s.label, .available = models == null }) catch {};
    }
    return out.items;
}

pub fn agentIndex(list: []const AgentChoice, stored: NewThreadDefaults) usize {
    for (list, 0..) |c, i| if (c.harness == stored.harness) return i;
    return 0;
}

pub fn modelIndex(list: []const ModelChoice, stored: NewThreadDefaults) usize {
    const s = stored.model orelse return 0;
    for (list, 0..) |c, i| if (c.id) |id| if (std.mem.eql(u8, id, s.id)) return i;
    return 0;
}

fn catalogOf(v: *SettingsView, cx: anytype) *const model.CatalogStore {
    return v.state.read(cx).catalog.read(cx);
}

fn agentsNow(v: *SettingsView, a: std.mem.Allocator, cx: anytype) []const AgentChoice {
    return agentChoices(a, catalogOf(v, cx).harnessList(), current(cx));
}

fn modelsNow(v: *SettingsView, a: std.mem.Allocator, cx: anytype) []const ModelChoice {
    const stored = current(cx);
    const models = if (stored.harness) |h| catalogOf(v, cx).modelList(h) else null;
    return modelChoices(a, models, stored);
}

/// `select.spec` for `.default_agent` / `.default_model` (plain text rows,
/// so macOS shows a native pop-up button).
pub fn spec(v: *SettingsView, id: select.SelectId, a: std.mem.Allocator, cx: anytype) select.Spec {
    var opts: std.ArrayList(select.Option) = .empty;
    const stored = current(cx);
    if (id == .default_agent) {
        const list = agentsNow(v, a, cx);
        for (list) |c| opts.append(a, .{ .label = c.label, .detail = if (c.available) null else unavailable }) catch {};
        return .{ .label = "Default agent", .options = opts.items, .selected = agentIndex(list, stored), .width = 200 };
    }
    const list = modelsNow(v, a, cx);
    for (list) |c| opts.append(a, .{ .label = c.label, .detail = if (c.available) null else unavailable }) catch {};
    return .{ .label = "Default model", .options = opts.items, .selected = modelIndex(list, stored), .width = 200 };
}

/// Apply row `ix` of `id`. A new agent resets the model to Last used.
pub fn commit(v: *SettingsView, id: select.SelectId, ix: usize, cx: *Context(SettingsView)) void {
    const a = zpui.window.arena_mod.frameAllocator();
    const stored = current(cx);
    if (id == .default_agent) {
        const list = agentsNow(v, a, cx);
        if (ix >= list.len) return;
        const h = list[ix].harness;
        if (h == stored.harness) return;
        composer_store.setPreferred(cx.app, .{ .harness = h });
        ensureModels(v, cx);
    } else {
        const list = modelsNow(v, a, cx);
        if (ix >= list.len or stored.harness == null) return;
        const c = list[ix];
        composer_store.setPreferred(cx.app, .{
            .harness = stored.harness,
            .model = if (c.id) |mid| .{ .id = mid, .label = c.label } else null,
        });
    }
    cx.notify();
}

/// Load the default agent's model list (the Default model rows).
pub fn ensureModels(v: *SettingsView, cx: anytype) void {
    const h = current(cx).harness orelse return;
    const catalog = v.state.read(cx).catalog;
    const c = catalog.read(cx);
    if (c.modelList(h) != null or c.models_loading.contains(h)) return;
    // Nothing to ask while the engine is away (`loadModels` would fail).
    if (!c.engine.read(cx).isReady()) return;
    catalog.update(cx, model.CatalogStore.loadModels, .{ h, false });
}

fn agentDescription(stored: NewThreadDefaults) []const u8 {
    return if (stored.harness == null) "New threads start with the agent you used last." else "New threads start with this agent when it is enabled.";
}

fn modelDescription(stored: NewThreadDefaults) []const u8 {
    return if (stored.model == null) "The model you last used with this agent." else "Falls back to the last used model if it goes away.";
}

/// The "New threads" card: Default agent, then (with an agent picked)
/// Default model.
pub fn card(v: *SettingsView, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    composer_store.ensure(cx.app);
    ensureModels(v, cx);
    const stored = current(cx);
    var c = w.sectionCard(t).child(w.cardRow(t, true)
        .child(w.textBlock(t, "Default agent", &.{.{ .text = agentDescription(stored) }}).minW0())
        .child(select.render(v, .default_agent, t, cx)));
    if (stored.harness != null) c = c.child(w.cardRow(t, false)
        .child(w.textBlock(t, "Default model", &.{.{ .text = modelDescription(stored) }}).minW0())
        .child(select.render(v, .default_model, t, cx)));
    return c;
}

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;

const catalog_fixture = [_]protocol.HarnessDescriptor{
    .{ .id = .mock, .name = "Mock", .supportsSteering = true, .steeringMode = .@"step-boundary", .reasoningLevels = &.{}, .enabled = false },
    .{ .id = .@"claude-code", .name = "Claude Code", .supportsSteering = true, .steeringMode = .@"step-boundary", .reasoningLevels = &.{} },
    .{ .id = .codex, .name = "Codex", .supportsSteering = true, .steeringMode = .@"turn-boundary", .reasoningLevels = &.{}, .enabled = false },
    .{ .id = .cursor, .name = "Cursor", .supportsSteering = false, .steeringMode = .@"turn-boundary", .reasoningLevels = &.{}, .installed = false },
};

test "agent rows: Last used, the enabled installed agents, then an unavailable stored one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fresh = agentChoices(a, &catalog_fixture, .{});
    try testing.expectEqual(@as(usize, 2), fresh.len);
    try testing.expectEqualStrings(last_used, fresh[0].label);
    try testing.expectEqualStrings("Claude Code", fresh[1].label);
    try testing.expectEqual(@as(usize, 0), agentIndex(fresh, .{}));

    // Codex was the default, then got switched off in Providers.
    const stale = agentChoices(a, &catalog_fixture, .{ .harness = .codex });
    try testing.expectEqual(@as(usize, 3), stale.len);
    try testing.expectEqualStrings("Codex", stale[2].label);
    try testing.expect(!stale[2].available);
    try testing.expectEqual(@as(usize, 2), agentIndex(stale, .{ .harness = .codex }));
}

test "model rows: Last used, the agent's models, then a stored model by availability" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const models = [_]protocol.Model{ .{ .id = "opus", .label = "Opus" }, .{ .id = "sonnet", .label = "Sonnet" } };
    const pick: NewThreadDefaults = .{ .harness = .@"claude-code", .model = .{ .id = "sonnet", .label = "Sonnet" } };
    const loaded = modelChoices(a, &models, pick);
    try testing.expectEqual(@as(usize, 3), loaded.len);
    try testing.expectEqual(@as(usize, 2), modelIndex(loaded, pick));
    try testing.expectEqual(@as(usize, 0), modelIndex(loaded, .{ .harness = .@"claude-code" }));

    // List still loading: the stored pick is the row (and is available).
    const pending = modelChoices(a, null, pick);
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expect(pending[1].available);
    try testing.expectEqual(@as(usize, 1), modelIndex(pending, pick));

    // Loaded without it: listed as unavailable.
    const gone: NewThreadDefaults = .{ .harness = .@"claude-code", .model = .{ .id = "haiku-2", .label = "Haiku 2" } };
    const rows = modelChoices(a, &models, gone);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expect(!rows[3].available);
    try testing.expectEqual(@as(usize, 3), modelIndex(rows, gone));
}
