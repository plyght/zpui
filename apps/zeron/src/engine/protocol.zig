//! Zig mirrors of the engine's core wire types.
//!
//! Sources: zeron `crates/proto/src/{workspace,entities,agent,sidebar_pins}.rs`,
//! `crates/doc/src/{schema,parts,commands,queue,transcript_delta}.rs`, and the
//! param structs in `crates/engine/src/rpc.rs`.
//!
//! Conventions:
//! - Field names are the exact JSON keys (camelCase almost everywhere). A few
//!   serde types lack `rename_all` and keep snake_case keys on the wire:
//!   `ToolCall.editFile.{old_string,new_string}` and `SidebarSection.session_ids`.
//! - Enum tags are the exact wire strings (`@"claude-code"`, `awaitingInput`).
//! - `Option<T>` → `?T = null`; `#[serde(default)]` collections → `= &.{}`.
//! - Internally tagged enums use `json_util.Tagged` with the serde tag name.
//! - Timestamps: `DateTime<Utc>` travels as an RFC 3339 string; `i64` epoch
//!   millis where the Rust field is an integer.
//! Decode with `ignore_unknown_fields = true` (serde's default leniency);
//! encode with `emit_null_optional_fields = false`.

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const json_util = @import("json_util.zig");

/// Arbitrary JSON (`serde_json::Value`).
pub const Value = json.Value;
/// `serde_json::Map<String, Value>`.
pub const JsonMap = json.ArrayHashMap(json.Value);

fn TaggedImpl(comptime T: type, comptime tag: []const u8) type {
    return json_util.Tagged(T, tag);
}

// ── engine identity ─────────────────────────────────────────────────────

pub const WorkspaceScope = enum { local, synced, development };

/// Capability strings (`zeron_proto::capabilities`).
pub const capabilities = struct {
    pub const composer_references_v1 = "composer-references-v1";
    pub const message_queue_v1 = "message-queue-v1";
    pub const message_queue_actions_v1 = "message-queue-actions-v1";
    pub const message_queue_attachments_v1 = "message-queue-attachments-v1";
    pub const message_queue_clean_attachment_text_v1 = "message-queue-clean-attachment-text-v1";
    pub const message_queue_edit_lease_v1 = "message-queue-edit-lease-v1";
    pub const harness_updates_v1 = "harness-updates-v1";
    /// `zeron_proto::voice::remote::CAPABILITY`.
    pub const voice_client_media_v1 = "voice-client-media-v1";
};

/// `zeron_proto::voice::ORCHESTRATOR_CHAT_PREFIX`: id prefix of the hidden
/// chat that hosts a voice orchestrator session (never a sidebar row).
pub const voice_orchestrator_chat_prefix = "voice-orchestrator-";

/// `zeron_proto::voice::is_orchestrator_chat`.
pub fn isOrchestratorChat(chat_id: []const u8) bool {
    return std.mem.startsWith(u8, chat_id, voice_orchestrator_chat_prefix);
}

/// `EngineInfo` reply.
pub const EngineInfo = struct {
    deviceId: []const u8,
    workspaceScope: WorkspaceScope,
    cursorSdkVersion: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},

    pub fn supports(self: EngineInfo, capability: []const u8) bool {
        for (self.capabilities) |c| if (std.mem.eql(u8, c, capability)) return true;
        return false;
    }
};

/// `LocalDevice` reply.
pub const LocalDevice = struct { deviceId: []const u8 };

// ── auth ────────────────────────────────────────────────────────────────

pub const UserProfile = struct {
    id: []const u8,
    email: []const u8,
    name: ?[]const u8 = null,
};

/// `AuthStatus` stream item, tagged by `state`.
pub const AuthState = union(enum) {
    signedOut,
    needsOrganization: struct { user: UserProfile },
    signedIn: struct { user: UserProfile, orgId: ?[]const u8 = null },

    const Impl = TaggedImpl(@This(), "state");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;
};

// ── agent / harness ─────────────────────────────────────────────────────

pub const HarnessId = enum {
    @"claude-code",
    codex,
    cursor,
    devin,
    grok,
    hermes,
    pi,
    opencode,
    antigravity,
    mock,
};

pub const ReasoningLevel = enum { minimal, low, medium, high, xhigh, max, ultra, ultracode, ultrathink };
pub const SandboxLevel = enum { @"read-only", @"workspace-write", @"danger-full-access" };
pub const SteeringMode = enum { @"step-boundary", @"turn-boundary" };

/// One `ListHarnesses` entry (`zeron_engine::registry::HarnessDescriptor`).
pub const HarnessDescriptor = struct {
    id: HarnessId,
    name: []const u8,
    supportsSteering: bool,
    steeringMode: SteeringMode,
    reasoningLevels: []const ReasoningLevel,
    installed: bool = true,
    canInstall: bool = false,
    enabled: ?bool = null,
};

pub const ModelOptionChoice = struct { id: []const u8, label: []const u8 };

pub const ModelOption = struct {
    id: []const u8,
    label: []const u8,
    choices: []const ModelOptionChoice,
    defaultChoice: []const u8,
};

/// One `ListModels` entry.
pub const Model = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    reasoningLevels: []const ReasoningLevel = &.{},
    options: []const ModelOption = &.{},
};

pub const McpServer = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: json.ArrayHashMap([]const u8) = .{},
};

pub const WorktreeSpec = struct {
    repoPath: []const u8,
    base: []const u8,
    spaceId: ?[]const u8 = null,
};

pub const RunRequest = struct {
    prompt: []const u8,
    harness: ?HarnessId = null,
    model: ?[]const u8 = null,
    reasoning: ?ReasoningLevel = null,
    modelOptions: JsonMap = .{},
    cwd: []const u8,
    sandbox: SandboxLevel,
    autoApprove: bool = false,
    @"resume": ?[]const u8 = null,
    attachments: []const []const u8 = &.{},
    worktree: ?WorktreeSpec = null,
    mcp: ?McpServer = null,
};

pub const TodoStatus = enum { pending, inProgress, completed };

pub const TodoItem = struct {
    text: []const u8,
    done: bool,
    /// Lenient in Rust (`deserialize_with`): unknown strings decode as absent.
    status: ?LenientTodoStatus = null,

    pub fn effectiveStatus(self: TodoItem) TodoStatus {
        if (self.done) return .completed;
        return if (self.status) |s| s.toStatus() else .pending;
    }
};

/// `TodoStatus` that tolerates unknown values (mapped to `pending`).
pub const LenientTodoStatus = enum {
    pending,
    inProgress,
    completed,
    unknown,

    pub fn toStatus(s: LenientTodoStatus) TodoStatus {
        return switch (s) {
            .pending, .unknown => .pending,
            .inProgress => .inProgress,
            .completed => .completed,
        };
    }

    const Impl = json_util.OpenEnum(@This(), .unknown);
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
};

/// `zeron_proto::ToolCall`, tagged by `kind`. Variant fields carry no
/// `rename_all`, so `editFile` keeps snake_case keys.
pub const ToolCall = union(enum) {
    exec: struct { command: []const u8 },
    readFile: struct { path: []const u8 },
    writeFile: struct { path: []const u8, content: ?[]const u8 = null },
    editFile: struct { path: []const u8, old_string: ?[]const u8 = null, new_string: ?[]const u8 = null },
    applyPatch: struct { path: ?[]const u8 = null },
    search: struct { pattern: []const u8, path: ?[]const u8 = null },
    glob: struct { pattern: []const u8 },
    webFetch: struct { url: []const u8, prompt: ?[]const u8 = null },
    webSearch: struct { query: []const u8 },
    todo: struct { items: []const TodoItem = &.{} },
    mcp: struct { server: []const u8, tool: []const u8, input: ?Value = null },
    unknown: struct { name: []const u8, input: ?Value = null },

    const Impl = TaggedImpl(@This(), "kind");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;

    /// `ToolCall::is_subagent_spawn`.
    pub fn isSubagentSpawn(self: ToolCall) bool {
        const name = switch (self) {
            .unknown => |u| u.name,
            .mcp => |m| m.tool,
            else => return false,
        };
        return std.mem.eql(u8, name, "Agent") or std.mem.startsWith(u8, name, "Agent: ");
    }
};

pub const ToolDiff = struct {
    path: []const u8,
    oldText: ?[]const u8 = null,
    newText: []const u8,
};

pub const ToolDiffStat = struct {
    path: []const u8,
    additions: u64,
    deletions: u64,
};

pub const UserInputQuestion = struct {
    id: []const u8,
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
    multiSelect: bool = false,
    prefill: ?[]const u8 = null,
    multiline: bool = false,
};

pub const UserInputAnswer = struct {
    questionId: []const u8,
    labels: []const []const u8,
};

pub const ContextUsage = struct {
    tokens: ?u64 = null,
    window: ?u64 = null,

    pub fn fraction(self: ContextUsage) ?f64 {
        const t = self.tokens orelse return null;
        const w = self.window orelse return null;
        if (w == 0) return null;
        return @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(w));
    }
};

// ── transcript ──────────────────────────────────────────────────────────

pub const MessageRole = enum { user, assistant, system };
pub const MessageStatus = enum { streaming, complete, aborted };
pub const SubagentStatus = enum { running, done, failed };

/// `zeron_doc::MessagePart`, tagged by `kind`.
pub const MessagePart = union(enum) {
    text: struct { id: []const u8, text: []const u8 },
    image: struct { id: []const u8, path: []const u8, name: []const u8, mimeType: []const u8 },
    reasoning: struct { id: []const u8, text: []const u8 },
    tool: Tool,
    input: struct {
        id: []const u8,
        requestId: []const u8,
        questions: []const UserInputQuestion,
        resolved: bool = false,
    },
    @"error": struct { id: []const u8, message: []const u8 },
    fork: struct { id: []const u8, sourceChatId: []const u8, sourceTitle: []const u8 },

    pub const Tool = struct {
        id: []const u8,
        call: ToolCall,
        isError: bool = false,
        resolved: bool = false,
        output: ?[]const u8 = null,
        diff: ?ToolDiff = null,
        outputRef: ?[]const u8 = null,
        outputBytes: ?u64 = null,
        diffRef: ?[]const u8 = null,
        diffStats: ?[]const ToolDiffStat = null,
        subagentRef: ?[]const u8 = null,
        subagentStatus: ?SubagentStatus = null,
        subagentTail: ?[]const u8 = null,
    };

    const Impl = TaggedImpl(@This(), "kind");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;

    pub fn id(self: MessagePart) []const u8 {
        return switch (self) {
            inline else => |p| p.id,
        };
    }

    /// The streaming text body of `text`/`reasoning` parts.
    pub fn textBody(self: *MessagePart) ?*[]const u8 {
        return switch (self.*) {
            .text => |*p| &p.text,
            .reasoning => |*p| &p.text,
            else => null,
        };
    }
};

/// One transcript row (`zeron_doc::SessionMessageEntry`).
pub const SessionMessageEntry = struct {
    id: []const u8,
    role: MessageRole,
    parts: []MessagePart,
    /// Epoch millis.
    createdAt: i64,
    deviceId: []const u8,
    status: ?MessageStatus = null,
    continuationOf: ?[]const u8 = null,
    durationMs: ?i64 = null,
};

/// `{after, entry}`: insert/replace `entry` after `after` (`null` = head).
pub const TranscriptUpsert = struct {
    after: ?[]const u8 = null,
    entry: SessionMessageEntry,
};

/// Pure text-tail append to one part; `len` is the part's byte length after it.
pub const TextAppend = struct {
    entry: []const u8,
    part: []const u8,
    text: []const u8,
    len: usize,
};

/// `TranscriptFrame` — serde `untagged`: `{reset}` or a delta.
pub const TranscriptFrame = union(enum) {
    reset: []SessionMessageEntry,
    delta: Delta,

    pub const Delta = struct {
        upsert: []const TranscriptUpsert = &.{},
        append: []const TextAppend = &.{},
        remove: []const []const u8 = &.{},
        /// Expected transcript length after applying (desync tripwire).
        count: usize,
    };

    pub fn jsonParse(gpa: Allocator, source: anytype, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!TranscriptFrame {
        return jsonParseFromValue(gpa, try json.innerParse(json.Value, gpa, source, options), options);
    }

    pub fn jsonParseFromValue(gpa: Allocator, value: json.Value, options: json.ParseOptions) json.ParseFromValueError!TranscriptFrame {
        if (value != .object) return error.UnexpectedToken;
        var lenient = options;
        lenient.ignore_unknown_fields = true;
        if (value.object.get("reset")) |reset| {
            return .{ .reset = try json.innerParseFromValue([]SessionMessageEntry, gpa, reset, lenient) };
        }
        return .{ .delta = try json.innerParseFromValue(Delta, gpa, value, lenient) };
    }

    pub fn jsonStringify(self: TranscriptFrame, jws: anytype) !void {
        switch (self) {
            .reset => |entries| {
                try jws.beginObject();
                try jws.objectField("reset");
                try jws.write(entries);
                try jws.endObject();
            },
            .delta => |d| try jws.write(d),
        }
    }
};

/// Presentation watermark: entryId → partId → text byte length.
pub const TranscriptBaseline = struct {
    entries: json.ArrayHashMap(json.ArrayHashMap(usize)) = .{},
};

/// One `WatchDocMessages` stream item: a flattened frame plus host context.
pub const TranscriptUpdate = struct {
    frame: TranscriptFrame,
    contextUsage: ?ContextUsage = null,
    replayBaseline: ?TranscriptBaseline = null,
    /// Set on the `openingTail` preview: older history is still loading.
    historyPending: bool = false,

    pub fn jsonParse(gpa: Allocator, source: anytype, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!TranscriptUpdate {
        return jsonParseFromValue(gpa, try json.innerParse(json.Value, gpa, source, options), options);
    }

    pub fn jsonParseFromValue(gpa: Allocator, value: json.Value, options: json.ParseOptions) json.ParseFromValueError!TranscriptUpdate {
        if (value != .object) return error.UnexpectedToken;
        var lenient = options;
        lenient.ignore_unknown_fields = true;
        const obj = value.object;
        return .{
            .frame = try TranscriptFrame.jsonParseFromValue(gpa, value, lenient),
            .contextUsage = if (obj.get("contextUsage")) |v| try json.innerParseFromValue(?ContextUsage, gpa, v, lenient) else null,
            .replayBaseline = if (obj.get("replayBaseline")) |v| try json.innerParseFromValue(?TranscriptBaseline, gpa, v, lenient) else null,
            .historyPending = if (obj.get("historyPending")) |v| v == .bool and v.bool else false,
        };
    }

    pub fn jsonStringify(self: TranscriptUpdate, jws: anytype) !void {
        try jws.beginObject();
        switch (self.frame) {
            .reset => |entries| {
                try jws.objectField("reset");
                try jws.write(entries);
            },
            .delta => |d| {
                try jws.objectField("upsert");
                try jws.write(d.upsert);
                try jws.objectField("append");
                try jws.write(d.append);
                try jws.objectField("remove");
                try jws.write(d.remove);
                try jws.objectField("count");
                try jws.write(d.count);
            },
        }
        if (self.contextUsage) |cu| {
            try jws.objectField("contextUsage");
            try jws.write(cu);
        }
        if (self.replayBaseline) |rb| {
            try jws.objectField("replayBaseline");
            try jws.write(rb);
        }
        if (self.historyPending) {
            try jws.objectField("historyPending");
            try jws.write(true);
        }
        try jws.endObject();
    }
};

// ── commands & queue ────────────────────────────────────────────────────

/// `zeron_doc::SessionCommandPayload`, tagged by `kind`.
pub const SessionCommandPayload = union(enum) {
    run: struct { request: RunRequest, messageId: []const u8 },
    steer: struct { prompt: []const u8, messageId: ?[]const u8 = null },
    interrupt,
    respondInput: struct { requestId: []const u8, answers: []const UserInputAnswer },

    const Impl = TaggedImpl(@This(), "kind");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;
};

pub const AttachmentTransfer = struct { uploadId: []const u8, fileName: []const u8 };

/// `QueueDeliveryGate`, tagged by `kind` (fields camelCase).
pub const QueueDeliveryGate = union(enum) {
    editing: struct {
        leaseId: []const u8,
        ownerDeviceId: []const u8,
        ownerInstanceId: []const u8,
        acquiredAtMs: i64,
        expiresAtMs: i64,
        baseTextHash: []const u8,
    },
    reviewRequired: struct {
        previousLeaseId: []const u8,
        ownerDeviceId: []const u8,
        sinceMs: i64,
        baseTextHash: []const u8,
    },

    const Impl = TaggedImpl(@This(), "kind");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;
};

pub const QueuedMessage = struct {
    id: []const u8,
    text: []const u8,
    attachments: []const []const u8 = &.{},
    holdForTurnEnd: bool = false,
    issuedBy: []const u8,
    issuedAt: i64,
    editedAt: ?i64 = null,
    deliveryGate: ?QueueDeliveryGate = null,
};

/// `WatchQueue` stream item.
pub const QueueSnapshot = struct { items: []const QueuedMessage = &.{} };

// ── workspace registry ──────────────────────────────────────────────────

pub const ChatConfig = struct {
    harness: HarnessId,
    model: ?[]const u8 = null,
    reasoning: ?ReasoningLevel = null,
    modelOptions: JsonMap = .{},
    sandbox: SandboxLevel,
};

pub const ConversationSourceContext = struct {
    checkoutId: []const u8,
    repoRoot: []const u8,
    cwd: []const u8,
    branch: []const u8,
    headSha: ?[]const u8 = null,
    observedAt: []const u8,
};

/// `WatchChats` stream items are `[]Chat` snapshots.
pub const Chat = struct {
    id: []const u8,
    deviceId: []const u8,
    title: ?[]const u8 = null,
    archived: bool,
    cwd: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    checkoutId: ?[]const u8 = null,
    sourceContext: ?ConversationSourceContext = null,
    config: ?ChatConfig = null,
    lastMessagePreview: ?[]const u8 = null,
    lastMessageAt: ?[]const u8 = null,
    createdAt: []const u8,
    harnessSessionId: ?[]const u8 = null,
    harnessSessionCwd: ?[]const u8 = null,
    spaceId: ?[]const u8 = null,
    lastSeenAt: ?[]const u8 = null,
    roomGen: ?u32 = null,
    parentChatId: ?[]const u8 = null,

    /// `Chat::is_top_level`: neither another chat's worker (`parentChatId`)
    /// nor a hidden voice orchestrator.
    pub fn isTopLevel(self: Chat) bool {
        return self.parentChatId == null and !isOrchestratorChat(self.id);
    }

    /// RFC 3339 UTC timestamps from the engine compare lexicographically.
    pub fn unseen(self: Chat) bool {
        const msg = self.lastMessageAt orelse return false;
        const seen = self.lastSeenAt orelse return true;
        return std.mem.order(u8, msg, seen) == .gt;
    }
};

/// `WatchSpaces` items are `[]Space`.
pub const Space = struct {
    id: []const u8,
    deviceId: []const u8,
    path: []const u8,
    name: ?[]const u8 = null,
    gitDetected: bool = false,
    gitCheckedAt: ?[]const u8 = null,
    checkoutId: ?[]const u8 = null,
    /// Owner-stamped repository identity shared by every clone and worktree
    /// (`commit:<sha>`, `host/owner/repo`, or `local:<hash>`). Opaque: spaces
    /// with equal ids are one project (`view.projectKey`).
    repositoryId: ?[]const u8 = null,
    createdAt: []const u8,
};

/// `WatchDevices` items are `[]Device`.
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    platform: []const u8,
    lastSeenAt: ?[]const u8 = null,
    createdAt: ?[]const u8 = null,
    version: ?[]const u8 = null,
    cursorSdkVersion: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},
};

pub const SessionStatus = enum { idle, working, awaitingInput, errored };

/// Treat a session row as stale after this long without updates.
pub const session_stale_ms = 45_000;

/// `WatchSessions` items are `[]Session`.
pub const Session = struct {
    lastCompletedTurn: ?[]const u8 = null,
    chatId: []const u8,
    deviceId: []const u8,
    status: SessionStatus,
    startedAt: ?[]const u8 = null,
    updatedAt: []const u8,
};

/// No `rename_all` in Rust: `session_ids` stays snake_case on the wire.
pub const SidebarSection = struct {
    id: []const u8,
    name: []const u8,
    session_ids: []const []const u8 = &.{},
    collapsed: bool = false,
};

pub const SidebarPreferences = struct {
    pinnedSessionIds: []const []const u8 = &.{},
    sections: []const SidebarSection = &.{},
};

/// `WatchSidebarPreferences` stream item.
pub const SidebarPreferencesState = struct {
    revision: u64 = 0,
    synced: bool,
    initialized: bool,
    pinnedSessionIds: []const []const u8 = &.{},
    sections: []const SidebarSection = &.{},

    pub fn canEdit(self: SidebarPreferencesState) bool {
        return self.synced or self.initialized;
    }
};

pub const SidebarSectionChange = union(enum) {
    create: struct { id: []const u8, name: []const u8 },
    rename: struct { id: []const u8, name: []const u8 },
    collapse: struct { id: []const u8, collapsed: bool },
    delete: struct { id: []const u8 },
    assign: struct { sessionId: []const u8, sectionId: ?[]const u8 = null },
    import: struct { sections: []const SidebarSection },

    const Impl = TaggedImpl(@This(), "action");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;
};

pub const SidebarPinChange = union(enum) {
    pin: struct { sessionId: []const u8, after: ?[]const u8 = null, before: ?[]const u8 = null },
    move: struct { sessionId: []const u8, after: ?[]const u8 = null, before: ?[]const u8 = null },
    unpin: struct { sessionId: []const u8 },
    section: struct { change: SidebarSectionChange },

    const Impl = TaggedImpl(@This(), "action");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;
};

/// `Mutate` params, tagged by `op`. Reply: `{ok: true}` (plus
/// `sidebarPreferences` for `changeSidebarPin`).
pub const Mutate = union(enum) {
    createChat: struct {
        chatId: []const u8,
        spaceId: ?[]const u8 = null,
        deviceId: ?[]const u8 = null,
        config: ?ChatConfig = null,
        branch: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        parentChatId: ?[]const u8 = null,
    },
    createSpace: struct {
        spaceId: []const u8,
        deviceId: []const u8,
        path: []const u8,
        name: ?[]const u8 = null,
        gitDetected: bool = false,
    },
    renameSpace: struct { spaceId: []const u8, name: ?[]const u8 = null },
    deleteSpace: struct { spaceId: []const u8 },
    renameChat: struct { chatId: []const u8, title: []const u8 },
    setChatBranch: struct { chatId: []const u8, branch: []const u8 },
    setChatCwd: struct { chatId: []const u8, cwd: []const u8 },
    setChatActivity: struct { chatId: []const u8, lastMessageAt: ?i64 = null, createdAt: ?i64 = null },
    setChatHost: struct { chatId: []const u8, deviceId: []const u8 },
    setChatArchived: struct { chatId: []const u8, archived: bool },
    changeSidebarPin: struct { change: SidebarPinChange },
    setChatConfig: struct { chatId: []const u8, config: ChatConfig },
    deleteChat: struct { chatId: []const u8 },
    renameDevice: struct { deviceId: []const u8, name: []const u8 },
    markChatSeen: struct { chatId: []const u8, at: ?i64 = null },

    const Impl = TaggedImpl(@This(), "op");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;
};

// ── connectivity ────────────────────────────────────────────────────────

pub const ConnectivityState = enum { disabled, offline, reconnecting, connected };

pub const ChatSyncState = enum {
    local,
    waiting,
    connecting,
    synced,
    offline,
    storageError,
    unknown,

    const Impl = json_util.OpenEnum(@This(), .unknown);
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
};

pub const ChatConnectivity = struct {
    chatId: []const u8,
    syncState: ChatSyncState = .unknown,
    connected: bool,
    deliveryLive: bool = false,
    pendingPushes: u64 = 0,
};

/// `WatchConnectivity` stream item.
pub const Connectivity = struct {
    state: ConnectivityState = .disabled,
    retryAtMs: i64 = 0,
    lastFailure: ?[]const u8 = null,
    chats: []const ChatConnectivity = &.{},
};

// ── diffs & git status ──────────────────────────────────────────────────

pub const DiffFileSummary = struct {
    path: []const u8,
    oldPath: ?[]const u8 = null,
    status: []const u8,
    additions: u32,
    deletions: u32,
    binary: bool = false,
};

/// `WatchCheckoutDiffs` items are `[]CheckoutDiff`; also `GetCheckoutDiff`.
pub const CheckoutDiff = struct {
    checkoutId: []const u8,
    deviceId: []const u8,
    cwd: []const u8,
    /// Unified patch (3 MiB cap; see `truncated`).
    patch: []const u8,
    files: []const DiffFileSummary,
    additions: u32,
    deletions: u32,
    truncated: bool,
    checksum: []const u8,
    updatedAt: []const u8,
};

pub const GitFileState = enum { unchanged, added, modified, deleted, renamed, copied, unmerged, untracked, typeChanged };

pub const GitFileStatus = struct {
    path: []const u8,
    oldPath: ?[]const u8 = null,
    index: GitFileState,
    worktree: GitFileState,
};

pub const CheckoutGitStatus = struct {
    checkoutId: []const u8,
    deviceId: []const u8,
    revision: []const u8,
    complete: bool,
    files: []const GitFileStatus,
};

/// `WatchWorkspaceGitStatus` stream item.
pub const WorkspaceGitStatusFrame = struct { status: ?CheckoutGitStatus = null };

pub const ChangeRequestState = enum { open, closed, merged };

pub const ChangeRequestSummary = struct {
    provider: []const u8,
    number: u64,
    title: []const u8,
    url: []const u8,
    state: ChangeRequestState,
    baseRef: []const u8,
    headRef: []const u8,
};

/// `WatchCheckoutChangeRequest` stream item.
pub const CheckoutChangeRequestStatus = struct {
    checkoutId: []const u8,
    deviceId: []const u8,
    cwd: []const u8,
    branch: []const u8,
    changeRequest: ?ChangeRequestSummary = null,
    updatedAt: []const u8,
};

/// `GetCheckoutFileDiffText` reply.
pub const CheckoutFileDiffText = struct {
    diffChecksum: []const u8,
    oldText: ?[]const u8 = null,
    newText: ?[]const u8 = null,
    oldContentHash: ?[]const u8 = null,
    newContentHash: ?[]const u8 = null,
    binary: bool,
    truncated: bool,
    stale: bool = false,
};

// ── terminals ───────────────────────────────────────────────────────────

/// `OpenTerminal` reply.
pub const TerminalSession = struct {
    id: []const u8,
    cwd: []const u8,
    shell: []const u8,
};

/// `SubscribeTerminal` stream item, tagged by `type`. `data` is base64.
pub const TerminalEvent = union(enum) {
    data: struct { seq: u64, data: []const u8 },
    exit: struct { seq: u64, exitCode: i32, signal: ?[]const u8 = null },

    const Impl = TaggedImpl(@This(), "type");
    pub const jsonParse = Impl.jsonParse;
    pub const jsonParseFromValue = Impl.jsonParseFromValue;
    pub const jsonStringify = Impl.jsonStringify;

    /// Decode a `data` event's bytes. Caller owns the result.
    pub fn decodeData(self: TerminalEvent, gpa: Allocator) ![]u8 {
        const b64 = switch (self) {
            .data => |d| d.data,
            .exit => return error.NotData,
        };
        const dec = std.base64.standard.Decoder;
        const out = try gpa.alloc(u8, try dec.calcSizeForSlice(b64));
        errdefer gpa.free(out);
        try dec.decode(out, b64);
        return out;
    }
};

// ── method params ───────────────────────────────────────────────────────

/// Request param shapes for the core methods (engine `*Params` structs).
pub const params = struct {
    pub const ChatId = struct { chatId: []const u8 };
    pub const WatchDocMessages = struct { chatId: []const u8, openingTail: ?bool = null };
    pub const QueueCommand = struct {
        chatId: []const u8,
        command: SessionCommandPayload,
        transfers: []const AttachmentTransfer = &.{},
    };
    pub const QueueMessage = struct {
        chatId: []const u8,
        text: []const u8,
        attachments: []const []const u8 = &.{},
        holdForTurnEnd: bool = false,
    };
    pub const ListModels = struct { harness: HarnessId, force: bool = false };
    pub const SetHarnessEnabled = struct { harness: HarnessId, enabled: bool };
    pub const OpenTerminal = struct { chatId: []const u8, cols: u16, rows: u16, cwd: ?[]const u8 = null };
    pub const SubscribeTerminal = struct { terminalId: []const u8, afterSeq: ?u64 = null };
    /// `data` is base64 (see `WriteTerminal.init`).
    pub const WriteTerminal = struct {
        terminalId: []const u8,
        data: []const u8,

        /// Base64-encode `bytes` into `buf` (needs `std.base64.standard.Encoder.calcSize(bytes.len)`).
        pub fn init(terminal_id: []const u8, bytes: []const u8, buf: []u8) WriteTerminal {
            return .{ .terminalId = terminal_id, .data = std.base64.standard.Encoder.encode(buf, bytes) };
        }
    };
    pub const ResizeTerminal = struct { terminalId: []const u8, cols: u16, rows: u16 };
    pub const TerminalId = struct { terminalId: []const u8 };
    /// `WorkspaceTarget` (flattened into several requests).
    pub const WorkspaceTarget = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
    };
    pub const GetCheckoutDiff = struct {
        cwd: []const u8,
        mode: []const u8 = "",
        baseRef: ?[]const u8 = null,
        chatId: ?[]const u8 = null,
        commitSha: ?[]const u8 = null,
    };
    pub const GetCheckoutFileDiffText = struct {
        checkoutId: []const u8,
        cwd: []const u8,
        path: []const u8,
        mode: []const u8 = "",
        baseRef: ?[]const u8 = null,
        chatId: ?[]const u8 = null,
        commitSha: ?[]const u8 = null,
        diffChecksum: []const u8,
    };
    pub const WatchCheckoutChangeRequest = struct { cwd: []const u8, branch: ?[]const u8 = null };
    pub const FetchToolBlob = struct { blobRef: []const u8 };
};

/// `QueueCommand` reply.
pub const QueueCommandReply = struct { commandId: []const u8 };
