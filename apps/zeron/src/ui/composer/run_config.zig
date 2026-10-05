//! Run-configuration resolution for the composer's model chip and sends — a
//! port of the `Pickers` resolution in zeron `crates/ui/src/pickers.rs`
//! (`effective_harness`, `effective_model_id`, `selected_model`,
//! `trait_ladder`, `effective_reasoning`, `resolved`, `default_reasoning`,
//! `clamp_reasoning`, `reasoning_label`, `offered_harnesses`) plus the exact
//! `SessionCommandPayload::Run { request: RunRequest, messageId }` the Rust
//! `Composer::send` queues.

const std = @import("std");
const engine = @import("zeron_engine");
const model = @import("zeron_model");

const protocol = engine.protocol;
pub const HarnessId = protocol.HarnessId;
pub const ReasoningLevel = protocol.ReasoningLevel;
pub const HarnessDescriptor = protocol.HarnessDescriptor;
pub const Model = protocol.Model;
pub const ChatConfig = protocol.ChatConfig;
pub const ComposerDefaults = model.composer_defaults.ComposerDefaults;
pub const NewThreadDefaults = model.composer_store.NewThreadDefaults;

pub fn reasoningLabel(level: ReasoningLevel) []const u8 {
    return switch (level) {
        .minimal => "Minimal",
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "X-High",
        .max => "Max",
        .ultra => "Ultra",
        .ultracode => "Ultracode",
        .ultrathink => "Ultrathink",
    };
}

/// The recommended default is High, then Medium, then the ladder's first.
pub fn defaultReasoning(ladder: []const ReasoningLevel) ?ReasoningLevel {
    if (std.mem.indexOfScalar(ReasoningLevel, ladder, .high) != null) return .high;
    if (std.mem.indexOfScalar(ReasoningLevel, ladder, .medium) != null) return .medium;
    return if (ladder.len > 0) ladder[0] else null;
}

/// Keep a level the ladder lists, else the model's default.
pub fn clampReasoning(level: ?ReasoningLevel, ladder: []const ReasoningLevel) ?ReasoningLevel {
    if (level) |l| if (std.mem.indexOfScalar(ReasoningLevel, ladder, l) != null) return l;
    return defaultReasoning(ladder);
}

/// `descriptor_enabled`: `enabled`, else detection (installed, not mock).
pub fn descriptorEnabled(d: HarnessDescriptor) bool {
    return d.enabled orelse (d.installed and d.id != .mock);
}

/// The harnesses the picker offers (installed + enabled; mock only when
/// explicitly allowed or when it is all there is). Writes into `out`.
pub fn offeredHarnesses(list: []const HarnessDescriptor, allow_mock: bool, out: []HarnessDescriptor) []HarnessDescriptor {
    var has_real = false;
    for (list) |d| if (d.id != .mock) {
        has_real = true;
    };
    var n: usize = 0;
    for (list) |d| {
        if (!allow_mock and has_real and d.id == .mock) continue;
        if (!(d.installed and (descriptorEnabled(d) or (allow_mock and d.id == .mock)))) continue;
        if (n == out.len) break;
        out[n] = d;
        n += 1;
    }
    return out[0..n];
}

/// The picker's draft (picks made in the open popover, not yet committed).
pub const Draft = struct {
    harness: ?HarnessId = null,
    model: ?[]const u8 = null,
    reasoning: ?ReasoningLevel = null,
};

/// Everything the resolution reads.
pub const Inputs = struct {
    draft: Draft = .{},
    /// The selected chat's config (null on the new-thread canvas or before
    /// the chat row has one).
    chat_config: ?*const ChatConfig = null,
    /// True for an existing chat (its own config wins over sticky defaults).
    existing_chat: bool = false,
    defaults: ?*const ComposerDefaults = null,
    /// The explicit Settings → General defaults for new threads (null
    /// fields = "Last used"). Existing threads never read them.
    preferred: ?*const NewThreadDefaults = null,
    /// The harness catalog (null while loading).
    harnesses: ?[]const HarnessDescriptor = null,
    /// `ListModels` for a harness (null while loading).
    models_for: *const fn (ctx: *const anyopaque, h: HarnessId) ?[]const Model = noModels,
    models_ctx: *const anyopaque = &{},
    allow_mock: bool = false,

    fn noModels(_: *const anyopaque, _: HarnessId) ?[]const Model {
        return null;
    }

    fn models(self: *const Inputs, h: HarnessId) ?[]const Model {
        return self.models_for(self.models_ctx, h);
    }
};

/// Whether `h` is offered right now (true while the catalog loads — trust
/// the stored pick until the list says otherwise).
fn isOffered(in: *const Inputs, h: HarnessId) bool {
    const list = in.harnesses orelse return true;
    var buf: [16]HarnessDescriptor = undefined;
    for (offeredHarnesses(list, in.allow_mock, &buf)) |o| if (o.id == h) return true;
    return false;
}

pub fn effectiveHarness(in: *const Inputs) ?HarnessId {
    if (in.draft.harness) |h| return h;
    if (in.chat_config) |c| return c.harness;
    // New thread: the explicit default agent when it is still offered
    // (installed + enabled), else the last-used one, else the first offered.
    if (!in.existing_chat) if (in.preferred) |p| if (p.harness) |h| {
        if (isOffered(in, h)) return h;
    };
    if (in.defaults) |d| if (d.harness) |h| {
        if (isOffered(in, h)) return h;
    };
    const list = in.harnesses orelse return null;
    var buf: [16]HarnessDescriptor = undefined;
    const offered = offeredHarnesses(list, in.allow_mock, &buf);
    return if (offered.len > 0) offered[0].id else null;
}

pub fn effectiveModelId(in: *const Inputs) ?[]const u8 {
    if (in.draft.model) |m| return m;
    if (in.existing_chat) return if (in.chat_config) |c| c.model else null;
    const h = effectiveHarness(in) orelse return null;
    if (preferredModel(in, h)) |m| return m.id;
    const d = in.defaults orelse return null;
    return if (d.modelFor(h)) |m| m.id else null;
}

/// The explicit default model for `h` on a new thread, unless the loaded
/// catalog no longer lists it (then the last-used pick takes over).
fn preferredModel(in: *const Inputs, h: HarnessId) ?model.composer_store.PreferredModel {
    if (in.existing_chat) return null;
    const p = in.preferred orelse return null;
    const m = p.modelFor(h) orelse return null;
    if (in.models(h)) |list| {
        for (list) |row| if (std.mem.eql(u8, row.id, m.id)) return m;
        return null;
    }
    return m; // models not loaded yet — trust the setting
}

/// An explicit id resolves to that catalog row (or nothing); none means the
/// catalog default (first row).
pub fn selectedModel(in: *const Inputs) ?*const Model {
    const h = effectiveHarness(in) orelse return null;
    const list = in.models(h) orelse return null;
    if (effectiveModelId(in)) |id| {
        for (list) |*m| if (std.mem.eql(u8, m.id, id)) return m;
        return null;
    }
    return if (list.len > 0) &list[0] else null;
}

pub fn traitLadder(in: *const Inputs) []const ReasoningLevel {
    const m = selectedModel(in) orelse return &.{};
    if (m.reasoningLevels.len > 0) return m.reasoningLevels;
    const h = effectiveHarness(in) orelse return &.{};
    const list = in.harnesses orelse return &.{};
    for (list) |d| if (d.id == h) return d.reasoningLevels;
    return &.{};
}

pub fn effectiveReasoning(in: *const Inputs) ?ReasoningLevel {
    const explicit: ?ReasoningLevel = in.draft.reasoning orelse if (in.existing_chat)
        (if (in.chat_config) |c| c.reasoning else null)
    else blk: {
        const d = in.defaults orelse break :blk null;
        if (effectiveHarness(in)) |h| if (d.reasoningFor(h, effectiveModelId(in))) |r| break :blk r;
        break :blk d.reasoning;
    };
    if (selectedModel(in) == null) return explicit;
    return clampReasoning(explicit, traitLadder(in));
}

/// The chip label: the selected model's label, else the remembered label,
/// else the configured id (never "Default model").
pub fn modelLabel(in: *const Inputs) ?[]const u8 {
    if (selectedModel(in)) |m| return m.label;
    const id = effectiveModelId(in) orelse return null;
    if (effectiveHarness(in)) |h| if (preferredModel(in, h)) |m| if (std.mem.eql(u8, m.id, id)) return m.label;
    if (in.defaults) |d| if (d.labelFor(id)) |l| return l;
    return id;
}

pub const Resolved = struct {
    harness: ?HarnessId,
    model: ?[]const u8,
    reasoning: ?ReasoningLevel,
    model_options: protocol.JsonMap = .{},
};

/// Fully-resolved run config (`Pickers::resolved`).
pub fn resolved(in: *const Inputs) Resolved {
    return .{
        .harness = effectiveHarness(in),
        .model = if (selectedModel(in)) |m| m.id else effectiveModelId(in),
        .reasoning = effectiveReasoning(in),
        .model_options = if (in.chat_config) |c| (if (in.existing_chat) c.modelOptions else .{}) else .{},
    };
}

pub const RunArgs = struct {
    prompt: []const u8,
    cwd: []const u8,
    message_id: []const u8,
    attachments: []const []const u8 = &.{},
    worktree: ?protocol.WorktreeSpec = null,
};

/// `SessionCommandPayload::Run` exactly as `Composer::send` builds it:
/// sandbox `workspace-write`, `autoApprove: false`, no resume, no MCP.
pub fn runCommand(r: Resolved, args: RunArgs) protocol.SessionCommandPayload {
    return .{ .run = .{
        .request = .{
            .mcp = null,
            .prompt = args.prompt,
            .harness = r.harness,
            .model = r.model,
            .reasoning = r.reasoning,
            .modelOptions = r.model_options,
            .cwd = args.cwd,
            .sandbox = .@"workspace-write",
            .autoApprove = false,
            .@"resume" = null,
            .attachments = args.attachments,
            .worktree = args.worktree,
        },
        .messageId = args.message_id,
    } };
}

/// Working directory for a send: existing chats keep theirs, new chats run
/// from the project folder, project-less sessions from `~`.
pub fn sendCwd(is_new: bool, space_path: ?[]const u8, existing_cwd: ?[]const u8) []const u8 {
    const cwd = if (is_new) (space_path orelse "~") else existing_cwd;
    return cwd orelse ".";
}

/// A random RFC 4122 v4 UUID (client-minted message / chat ids).
pub fn uuidV4(io: std.Io, out: *[36]u8) []const u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 0xf];
        o += 2;
    }
    return out[0..36];
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const catalog = [_]HarnessDescriptor{
    .{ .id = .mock, .name = "Mock", .supportsSteering = true, .steeringMode = .@"step-boundary", .reasoningLevels = &.{}, .enabled = false },
    .{ .id = .@"claude-code", .name = "Claude Code", .supportsSteering = true, .steeringMode = .@"step-boundary", .reasoningLevels = &.{ .low, .medium, .high, .max } },
    .{ .id = .codex, .name = "Codex", .supportsSteering = true, .steeringMode = .@"turn-boundary", .reasoningLevels = &.{ .minimal, .low, .medium } },
    .{ .id = .cursor, .name = "Cursor", .supportsSteering = false, .steeringMode = .@"turn-boundary", .reasoningLevels = &.{}, .installed = false },
};

const claude_models = [_]Model{
    .{ .id = "claude-opus-5", .label = "Fable" },
    .{ .id = "claude-sonnet-4-6", .label = "Sonnet 4.6", .reasoningLevels = &.{ .low, .medium } },
};

fn modelsFor(_: *const anyopaque, h: HarnessId) ?[]const Model {
    return if (h == .@"claude-code") &claude_models else null;
}

test "reasoning helpers" {
    try testing.expectEqual(ReasoningLevel.high, defaultReasoning(&.{ .low, .medium, .high, .xhigh }).?);
    try testing.expectEqual(ReasoningLevel.medium, defaultReasoning(&.{ .minimal, .low, .medium }).?);
    try testing.expectEqual(ReasoningLevel.minimal, defaultReasoning(&.{.minimal}).?);
    try testing.expect(defaultReasoning(&.{}) == null);
    try testing.expectEqual(ReasoningLevel.low, clampReasoning(.low, &.{ .low, .high }).?);
    try testing.expectEqual(ReasoningLevel.high, clampReasoning(.max, &.{ .low, .high }).?);
    try testing.expectEqualStrings("X-High", reasoningLabel(.xhigh));
}

test "offered harnesses drop mock and uninstalled" {
    var buf: [8]HarnessDescriptor = undefined;
    const offered = offeredHarnesses(&catalog, false, &buf);
    try testing.expectEqual(@as(usize, 2), offered.len);
    try testing.expectEqual(HarnessId.@"claude-code", offered[0].id);
}

test "new-thread resolution: first offered harness, default model, High" {
    const in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor };
    try testing.expectEqual(HarnessId.@"claude-code", effectiveHarness(&in).?);
    try testing.expectEqualStrings("Fable", modelLabel(&in).?);
    try testing.expectEqual(ReasoningLevel.high, effectiveReasoning(&in).?);
    const r = resolved(&in);
    try testing.expectEqualStrings("claude-opus-5", r.model.?);
}

test "draft and chat config precedence; reasoning clamps to the model ladder" {
    var in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .draft = .{ .model = "claude-sonnet-4-6", .reasoning = .max } };
    try testing.expectEqual(ReasoningLevel.medium, effectiveReasoning(&in).?);
    const cfg: ChatConfig = .{ .harness = .codex, .model = "gpt-5", .reasoning = .low, .sandbox = .@"workspace-write" };
    in = .{ .harnesses = &catalog, .models_for = modelsFor, .chat_config = &cfg, .existing_chat = true };
    try testing.expectEqual(HarnessId.codex, effectiveHarness(&in).?);
    try testing.expectEqualStrings("gpt-5", modelLabel(&in).?); // models not loaded: the id
    try testing.expectEqual(ReasoningLevel.low, effectiveReasoning(&in).?);
}

test "run command matches the Rust RunRequest shape on the wire" {
    const in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor };
    const cmd = runCommand(resolved(&in), .{ .prompt = "hi", .cwd = sendCwd(true, null, null), .message_id = "m1" });
    const s = try std.json.Stringify.valueAlloc(testing.allocator, cmd, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(
        \\{"kind":"run","request":{"prompt":"hi","harness":"claude-code","model":"claude-opus-5","reasoning":"high","modelOptions":{},"cwd":"~","sandbox":"workspace-write","autoApprove":false,"attachments":[]},"messageId":"m1"}
    , s);
    try testing.expectEqualStrings("/repo", sendCwd(false, "/x", "/repo"));
    try testing.expectEqualStrings(".", sendCwd(false, null, null));
}

// ---- explicit new-thread defaults (Settings → General) ---------------------------------

fn noneLoaded(_: *const anyopaque, _: HarnessId) ?[]const Model {
    return null;
}

/// Sticky memory: last used Codex, with a remembered model for both agents.
fn stickyFixture(a: std.mem.Allocator) !ComposerDefaults {
    var d: ComposerDefaults = .{};
    try d.rememberModel(a, .@"claude-code", "claude-sonnet-4-6", "Sonnet 4.6");
    try d.rememberModel(a, .codex, "gpt-5", "GPT-5");
    return d; // harness = codex (the last pick)
}

test "new thread: the explicit default agent and model win over last used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sticky = try stickyFixture(arena.allocator());
    const pref: NewThreadDefaults = .{ .harness = .@"claude-code", .model = .{ .id = "claude-opus-5", .label = "Fable" } };
    const in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &pref };
    try testing.expectEqual(HarnessId.@"claude-code", effectiveHarness(&in).?);
    try testing.expectEqualStrings("claude-opus-5", effectiveModelId(&in).?);
    try testing.expectEqualStrings("claude-opus-5", resolved(&in).model.?);

    // Default agent only ("Last used" model): that agent's remembered model.
    const agent_only: NewThreadDefaults = .{ .harness = .@"claude-code" };
    const in2: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &agent_only };
    try testing.expectEqualStrings("claude-sonnet-4-6", effectiveModelId(&in2).?);

    // Both "Last used": the Rust behaviour.
    const last_used: NewThreadDefaults = .{};
    const in3: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &last_used };
    try testing.expectEqual(HarnessId.codex, effectiveHarness(&in3).?);
    try testing.expectEqualStrings("gpt-5", effectiveModelId(&in3).?);

    // A provider switched in the picker leaves the other agent's default model alone.
    const in4: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &pref, .draft = .{ .harness = .codex } };
    try testing.expectEqualStrings("gpt-5", effectiveModelId(&in4).?);
}

test "existing threads keep their own agent and model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sticky = try stickyFixture(arena.allocator());
    const pref: NewThreadDefaults = .{ .harness = .@"claude-code", .model = .{ .id = "claude-opus-5", .label = "Fable" } };
    const cfg: ChatConfig = .{ .harness = .codex, .model = "gpt-5-mini", .reasoning = .low, .sandbox = .@"workspace-write" };
    const in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &pref, .chat_config = &cfg, .existing_chat = true };
    try testing.expectEqual(HarnessId.codex, effectiveHarness(&in).?);
    try testing.expectEqualStrings("gpt-5-mini", effectiveModelId(&in).?);
    // A chat row without a config yet still never takes the new-thread default.
    const bare: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &pref, .existing_chat = true };
    try testing.expectEqual(HarnessId.codex, effectiveHarness(&bare).?);
}

test "fallback: a disabled default agent yields to last used, then to the first offered" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sticky = try stickyFixture(arena.allocator());
    // Cursor is not installed; mock is disabled.
    const pref: NewThreadDefaults = .{ .harness = .cursor, .model = .{ .id = "cursor-fast", .label = "Fast" } };
    const in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &pref };
    try testing.expectEqual(HarnessId.codex, effectiveHarness(&in).?);
    try testing.expectEqualStrings("gpt-5", effectiveModelId(&in).?);

    // Turn Codex off as well: the last-used agent is gone too → the boot
    // default (first offered harness) and its catalog default model.
    var cat2 = catalog;
    cat2[2].enabled = false;
    const in2: Inputs = .{ .harnesses = &cat2, .models_for = modelsFor, .preferred = &pref };
    try testing.expectEqual(HarnessId.@"claude-code", effectiveHarness(&in2).?);
    try testing.expectEqualStrings("claude-opus-5", resolved(&in2).model.?);

    // Catalog still loading: trust the setting.
    const loading: Inputs = .{ .models_for = modelsFor, .defaults = &sticky, .preferred = &pref };
    try testing.expectEqual(HarnessId.cursor, effectiveHarness(&loading).?);
}

test "fallback: a default model gone from the catalog yields to last used, then the catalog default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sticky = try stickyFixture(arena.allocator());
    const pref: NewThreadDefaults = .{ .harness = .@"claude-code", .model = .{ .id = "claude-retired-3", .label = "Retired" } };
    const in: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .defaults = &sticky, .preferred = &pref };
    try testing.expectEqualStrings("claude-sonnet-4-6", effectiveModelId(&in).?);
    try testing.expectEqualStrings("Sonnet 4.6", modelLabel(&in).?);
    const no_memory: Inputs = .{ .harnesses = &catalog, .models_for = modelsFor, .preferred = &pref };
    try testing.expect(effectiveModelId(&no_memory) == null);
    try testing.expectEqualStrings("claude-opus-5", resolved(&no_memory).model.?);

    // Before the model list loads the chip names the default from the setting.
    const not_loaded: Inputs = .{ .harnesses = &catalog, .models_for = noneLoaded, .preferred = &pref };
    try testing.expectEqualStrings("claude-retired-3", effectiveModelId(&not_loaded).?);
    try testing.expectEqualStrings("Retired", modelLabel(&not_loaded).?);
}
