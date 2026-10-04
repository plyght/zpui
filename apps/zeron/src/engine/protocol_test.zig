//! JSON round trips for every protocol type. Samples are written the way
//! serde_json renders the Rust types (field names, tags, skip rules), then
//! decoded into the Zig type, re-encoded, and compared structurally.

const std = @import("std");
const json = std.json;
const testing = std.testing;
const p = @import("protocol.zig");

/// Structural JSON equality where an absent key equals `null`, `false`, `[]` or `{}`
/// (serde's `skip_serializing_if` vs. our always-emitted empty defaults).
fn jsonEql(a: json.Value, b: json.Value) bool {
    switch (a) {
        .object => |ao| {
            if (b != .object) return false;
            const bo = b.object;
            var it = ao.iterator();
            while (it.next()) |e| {
                if (bo.get(e.key_ptr.*)) |bv| {
                    if (!jsonEql(e.value_ptr.*, bv)) return false;
                } else if (!isEmpty(e.value_ptr.*)) return false;
            }
            var it2 = bo.iterator();
            while (it2.next()) |e| {
                if (ao.get(e.key_ptr.*) == null and !isEmpty(e.value_ptr.*)) return false;
            }
            return true;
        },
        .array => |aa| {
            if (b != .array or b.array.items.len != aa.items.len) return false;
            for (aa.items, b.array.items) |x, y| if (!jsonEql(x, y)) return false;
            return true;
        },
        .integer => |i| return switch (b) {
            .integer => |j| i == j,
            .float => |f| @as(f64, @floatFromInt(i)) == f,
            else => false,
        },
        .float => |f| return switch (b) {
            .float => |g| @abs(f - g) < 1e-6,
            .integer => |j| f == @as(f64, @floatFromInt(j)),
            else => false,
        },
        .string => |s| return b == .string and std.mem.eql(u8, s, b.string),
        .bool => |x| return b == .bool and b.bool == x,
        .null => return b == .null,
        .number_string => |s| return b == .number_string and std.mem.eql(u8, s, b.number_string),
    }
}

fn isEmpty(v: json.Value) bool {
    return switch (v) {
        .null => true,
        .array => |a| a.items.len == 0,
        .object => |o| o.count() == 0,
        .bool => |b| !b, // `skip_serializing_if = is_false` vs. emitted default
        else => false,
    };
}

fn roundTrip(arena: std.mem.Allocator, comptime T: type, sample: []const u8) !T {
    const decoded = json.parseFromSliceLeaky(T, arena, sample, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("decode {s} failed: {t}\n{s}\n", .{ @typeName(T), err, sample });
        return err;
    };
    const encoded = try json.Stringify.valueAlloc(arena, decoded, .{ .emit_null_optional_fields = false });
    const want = try json.parseFromSliceLeaky(json.Value, arena, sample, .{});
    const got = try json.parseFromSliceLeaky(json.Value, arena, encoded, .{});
    if (!jsonEql(want, got)) {
        std.debug.print("round trip mismatch for {s}\n want: {s}\n  got: {s}\n", .{ @typeName(T), sample, encoded });
        return error.RoundTripMismatch;
    }
    // Decoding from a Value (the RPC path) must agree with decoding from text.
    _ = try json.parseFromValueLeaky(T, arena, want, .{ .ignore_unknown_fields = true });
    return decoded;
}

test "engine identity and auth" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try roundTrip(a, p.EngineInfo,
        \\{"deviceId":"device-1","workspaceScope":"local","cursorSdkVersion":"1.0.31",
        \\ "capabilities":["composer-references-v1","message-queue-v1","message-queue-actions-v1",
        \\ "message-queue-attachments-v1","message-queue-clean-attachment-text-v1",
        \\ "message-queue-edit-lease-v1","harness-updates-v1"]}
    );
    const old = try roundTrip(a, p.EngineInfo,
        \\{"deviceId":"old","workspaceScope":"synced"}
    );
    try testing.expect(!old.supports(p.capabilities.message_queue_v1));
    _ = try roundTrip(a, p.LocalDevice,
        \\{"deviceId":"d"}
    );
    try testing.expect(try roundTrip(a, p.AuthState,
        \\{"state":"signedOut"}
    ) == .signedOut);
    _ = try roundTrip(a, p.AuthState,
        \\{"state":"needsOrganization","user":{"id":"u1","email":"a@b.c","name":null}}
    );
    const signed = try roundTrip(a, p.AuthState,
        \\{"state":"signedIn","user":{"id":"u1","email":"a@b.c","name":"Ann"},"orgId":"org_1"}
    );
    try testing.expectEqualStrings("org_1", signed.signedIn.orgId.?);
}

test "registry rows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try roundTrip(a, []p.Chat,
        \\[{"id":"c1","deviceId":"d1","title":"Fix the bug","archived":false,"cwd":"/src/app","branch":"main",
        \\  "checkoutId":"k1","sourceContext":{"checkoutId":"k1","repoRoot":"/src/app","cwd":"/src/app",
        \\  "branch":"main","headSha":"abc123","observedAt":"2026-01-02T03:04:05Z"},
        \\  "config":{"harness":"claude-code","model":"opus","reasoning":"high","modelOptions":{"fast":true},
        \\  "sandbox":"workspace-write"},"lastMessagePreview":"done","lastMessageAt":"2026-01-02T03:04:05.123Z",
        \\  "createdAt":"2026-01-01T00:00:00Z","harnessSessionId":"s-1","harnessSessionCwd":"/src/app",
        \\  "spaceId":"sp1","lastSeenAt":"2026-01-02T03:04:00Z","roomGen":2,"parentChatId":"c0"},
        \\ {"id":"c2","deviceId":"d1","title":null,"archived":true,"cwd":null,"branch":null,"checkoutId":null,
        \\  "config":null,"lastMessagePreview":null,"lastMessageAt":null,"createdAt":"2026-01-01T00:00:00Z"}]
    );
    _ = try roundTrip(a, []p.Space,
        \\[{"id":"sp1","deviceId":"d1","path":"/src/app","name":"App","gitDetected":true,
        \\  "gitCheckedAt":"2026-01-01T00:00:00Z","checkoutId":"k1","createdAt":"2026-01-01T00:00:00Z"}]
    );
    _ = try roundTrip(a, []p.Device,
        \\[{"id":"d1","name":"laptop","platform":"linux","lastSeenAt":null,"createdAt":"2026-01-01T00:00:00Z",
        \\  "version":"0.2.102","cursorSdkVersion":"1.0.31","capabilities":["message-queue-v1"]}]
    );
    _ = try roundTrip(a, []p.Session,
        \\[{"lastCompletedTurn":"turn-3","chatId":"c1","deviceId":"d1","status":"awaitingInput",
        \\  "startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:01Z"}]
    );
    const prefs = try roundTrip(a, p.SidebarPreferencesState,
        \\{"revision":7,"synced":true,"initialized":true,"pinnedSessionIds":["c1"],
        \\ "sections":[{"id":"s1","name":"Work","session_ids":["c2","c3"],"collapsed":true}]}
    );
    try testing.expect(prefs.canEdit());
    _ = try roundTrip(a, p.SidebarPreferences,
        \\{"pinnedSessionIds":[],"sections":[{"id":"s1","name":"Work","session_ids":[],"collapsed":false}]}
    );
}

test "Mutate: every op" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ops = [_][]const u8{
        \\{"op":"createChat","chatId":"c1","spaceId":"sp1","config":{"harness":"codex","model":null,
        \\ "reasoning":"medium","modelOptions":{},"sandbox":"read-only"},"branch":"main","cwd":"/w","parentChatId":"c0"}
        ,
        \\{"op":"createChat","chatId":"c2","deviceId":"d1"}
        ,
        \\{"op":"createSpace","spaceId":"sp1","deviceId":"d1","path":"/src","name":"Src","gitDetected":true}
        ,
        \\{"op":"renameSpace","spaceId":"sp1","name":null}
        ,
        \\{"op":"deleteSpace","spaceId":"sp1"}
        ,
        \\{"op":"renameChat","chatId":"c1","title":"New"}
        ,
        \\{"op":"setChatBranch","chatId":"c1","branch":"feat"}
        ,
        \\{"op":"setChatCwd","chatId":"c1","cwd":"/w2"}
        ,
        \\{"op":"setChatActivity","chatId":"c1","lastMessageAt":1700000000000,"createdAt":1690000000000}
        ,
        \\{"op":"setChatHost","chatId":"c1","deviceId":"d2"}
        ,
        \\{"op":"setChatArchived","chatId":"c1","archived":true}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"pin","sessionId":"c1","after":"c0","before":null}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"move","sessionId":"c1","after":null,"before":"c2"}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"unpin","sessionId":"c1"}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"section","change":{"action":"create","id":"s1","name":"W"}}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"section","change":{"action":"rename","id":"s1","name":"X"}}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"section","change":{"action":"collapse","id":"s1","collapsed":true}}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"section","change":{"action":"delete","id":"s1"}}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"section","change":{"action":"assign","sessionId":"c1","sectionId":"s1"}}}
        ,
        \\{"op":"changeSidebarPin","change":{"action":"section","change":{"action":"import","sections":[{"id":"s1","name":"W","session_ids":["c1"],"collapsed":false}]}}}
        ,
        \\{"op":"setChatConfig","chatId":"c1","config":{"harness":"pi","model":"m","reasoning":null,"modelOptions":{"k":"v"},"sandbox":"danger-full-access"}}
        ,
        \\{"op":"deleteChat","chatId":"c1"}
        ,
        \\{"op":"renameDevice","deviceId":"d1","name":"desk"}
        ,
        \\{"op":"markChatSeen","chatId":"c1","at":1700000000000}
        ,
    };
    for (ops) |op| _ = try roundTrip(a, p.Mutate, op);

    // Encoding from Zig produces the serde shape.
    const m: p.Mutate = .{ .renameChat = .{ .chatId = "c1", .title = "T" } };
    const bytes = try json.Stringify.valueAlloc(testing.allocator, m, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"op\":\"renameChat\",\"chatId\":\"c1\",\"title\":\"T\"}", bytes);
}

test "transcript entries: every MessagePart and ToolCall kind" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const entry = try roundTrip(a, p.SessionMessageEntry,
        \\{"id":"m1","role":"assistant","createdAt":1700000000000,"deviceId":"d1","status":"complete",
        \\ "continuationOf":"m0","durationMs":4200,"parts":[
        \\ {"kind":"text","id":"t0","text":"Hello"},
        \\ {"kind":"image","id":"i0","path":"/tmp/a.png","name":"a.png","mimeType":"image/png"},
        \\ {"kind":"reasoning","id":"r0","text":"thinking"},
        \\ {"kind":"tool","id":"k0","call":{"kind":"exec","command":"ls -la"},"isError":false,"resolved":true,
        \\  "output":"total 0","outputRef":"c1/k0","outputBytes":7},
        \\ {"kind":"tool","id":"k1","call":{"kind":"readFile","path":"a.zig"},"isError":false,"resolved":false},
        \\ {"kind":"tool","id":"k2","call":{"kind":"writeFile","path":"b.zig","content":"x"},"isError":false,"resolved":true,
        \\  "diff":{"path":"b.zig","oldText":null,"newText":"x"},"diffStats":[{"path":"b.zig","additions":1,"deletions":0}],
        \\  "diffRef":"c1/k2.diff"},
        \\ {"kind":"tool","id":"k3","call":{"kind":"editFile","path":"c.zig","old_string":"a","new_string":"b"},"isError":true,"resolved":true},
        \\ {"kind":"tool","id":"k4","call":{"kind":"applyPatch","path":"d.zig"},"isError":false,"resolved":true},
        \\ {"kind":"tool","id":"k5","call":{"kind":"search","pattern":"fn main","path":"src"},"isError":false,"resolved":true},
        \\ {"kind":"tool","id":"k6","call":{"kind":"glob","pattern":"**/*.zig"},"isError":false,"resolved":true},
        \\ {"kind":"tool","id":"k7","call":{"kind":"webFetch","url":"https://e.x","prompt":"sum"},"isError":false,"resolved":true},
        \\ {"kind":"tool","id":"k8","call":{"kind":"webSearch","query":"zig 0.17"},"isError":false,"resolved":true},
        \\ {"kind":"tool","id":"k9","call":{"kind":"todo","items":[{"text":"a","done":true},{"text":"b","done":false,"status":"inProgress"}]},"isError":false,"resolved":true},
        \\ {"kind":"tool","id":"ka","call":{"kind":"mcp","server":"zeron","tool":"Agent","input":{"model":"opus","n":[1,2]}},"isError":false,"resolved":false,
        \\  "subagentRef":"c9","subagentStatus":"running","subagentTail":"working…"},
        \\ {"kind":"tool","id":"kb","call":{"kind":"unknown","name":"Mystery","input":null},"isError":false,"resolved":false},
        \\ {"kind":"input","id":"q0","requestId":"req-1","resolved":false,"questions":[{"id":"q","header":"Pick",
        \\  "question":"Which?","options":["A","B"],"multiSelect":true,"prefill":"A","multiline":false}]},
        \\ {"kind":"error","id":"e0","message":"boom"},
        \\ {"kind":"fork","id":"f0","sourceChatId":"c0","sourceTitle":"Origin"}]}
    );
    try testing.expectEqual(@as(usize, 18), entry.parts.len);
    try testing.expectEqualStrings("b", entry.parts[6].tool.call.editFile.new_string.?);
    try testing.expect(entry.parts[13].tool.call.isSubagentSpawn());
    try testing.expectEqual(p.TodoStatus.inProgress, entry.parts[12].tool.call.todo.items[1].effectiveStatus());
    try testing.expectEqualStrings("e0", entry.parts[16].id());
}

test "TranscriptUpdate: reset, delta, baseline, opening tail" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const reset = try roundTrip(a, p.TranscriptUpdate,
        \\{"reset":[{"id":"m1","role":"user","parts":[{"kind":"text","id":"t0","text":"hi"}],"createdAt":1,"deviceId":"d"}],
        \\ "contextUsage":{"tokens":1200,"window":200000},
        \\ "replayBaseline":{"entries":{"m1":{"t0":2}}},"historyPending":true}
    );
    try testing.expect(reset.frame == .reset);
    try testing.expect(reset.historyPending);
    try testing.expectEqual(@as(usize, 2), reset.replayBaseline.?.entries.map.get("m1").?.map.get("t0").?);
    const delta = try roundTrip(a, p.TranscriptUpdate,
        \\{"upsert":[{"after":"m1","entry":{"id":"m2","role":"assistant","parts":[],"createdAt":2,"deviceId":"d","status":"streaming"}}],
        \\ "append":[{"entry":"m2","part":"t0","text":" more","len":12}],"remove":["m0"],"count":2,
        \\ "contextUsage":{"tokens":null,"window":null}}
    );
    try testing.expectEqual(@as(usize, 2), delta.frame.delta.count);
    // Older engines may omit every delta list.
    const bare = try roundTrip(a, p.TranscriptUpdate,
        \\{"count":0,"contextUsage":null}
    );
    try testing.expectEqual(@as(usize, 0), bare.frame.delta.upsert.len);
}

test "commands, queue" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmds = [_][]const u8{
        \\{"kind":"run","messageId":"m1","request":{"prompt":"go","harness":"claude-code","model":"opus",
        \\ "reasoning":"xhigh","modelOptions":{"fast":true},"cwd":"/w","sandbox":"workspace-write","autoApprove":true,
        \\ "resume":"sess-1","attachments":["/tmp/a.png"],"worktree":{"repoPath":"/w","base":"main","spaceId":"sp1"},
        \\ "mcp":{"name":"zeron","command":"zeron","args":["mcp"],"env":{"A":"1"}}}}
        ,
        \\{"kind":"run","messageId":"m2","request":{"prompt":"go","model":null,"reasoning":null,"modelOptions":{},
        \\ "cwd":"~","sandbox":"read-only","autoApprove":false,"resume":null}}
        ,
        \\{"kind":"steer","prompt":"also this","messageId":null}
        ,
        \\{"kind":"interrupt"}
        ,
        \\{"kind":"respondInput","requestId":"req-1","answers":[{"questionId":"q","labels":["A"]}]}
        ,
    };
    for (cmds) |c| _ = try roundTrip(a, p.SessionCommandPayload, c);

    _ = try roundTrip(a, p.params.QueueCommand,
        \\{"chatId":"c1","command":{"kind":"interrupt"},"transfers":[{"uploadId":"u1","fileName":"a.png"}]}
    );
    _ = try roundTrip(a, p.QueueCommandReply,
        \\{"commandId":"cmd-1"}
    );
    _ = try roundTrip(a, p.QueueSnapshot,
        \\{"items":[{"id":"q1","text":"next","attachments":["/a"],"holdForTurnEnd":true,"issuedBy":"d1","issuedAt":5,
        \\ "editedAt":6,"deliveryGate":{"kind":"editing","leaseId":"l","ownerDeviceId":"d1","ownerInstanceId":"i",
        \\ "acquiredAtMs":1,"expiresAtMs":2,"baseTextHash":"h"}},
        \\ {"id":"q2","text":"x","issuedBy":"d2","issuedAt":7,"deliveryGate":{"kind":"reviewRequired",
        \\ "previousLeaseId":"l","ownerDeviceId":"d1","sinceMs":3,"baseTextHash":"h"}}]}
    );
}

test "harnesses and models" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try roundTrip(a, []p.HarnessDescriptor,
        \\[{"id":"claude-code","name":"Claude Code","supportsSteering":true,"steeringMode":"step-boundary",
        \\  "reasoningLevels":["low","medium","high","max"],"installed":true,"canInstall":false,"enabled":true},
        \\ {"id":"opencode","name":"OpenCode","supportsSteering":false,"steeringMode":"turn-boundary",
        \\  "reasoningLevels":[],"installed":false,"canInstall":true}]
    );
    const legacy = try roundTrip(a, []p.HarnessDescriptor,
        \\[{"id":"mock","name":"Mock","supportsSteering":false,"steeringMode":"turn-boundary","reasoningLevels":[],"installed":true}]
    );
    try testing.expect(legacy[0].installed and legacy[0].enabled == null);
    _ = try roundTrip(a, []p.Model,
        \\[{"id":"opus","label":"Opus","description":"Most capable","reasoningLevels":["high","ultrathink"],
        \\  "options":[{"id":"speed","label":"Speed","choices":[{"id":"fast","label":"Fast"}],"defaultChoice":"fast"}]},
        \\ {"id":"mini","label":"Mini"}]
    );
    _ = try roundTrip(a, p.params.ListModels,
        \\{"harness":"codex","force":true}
    );
}

test "diffs, git status, change requests" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try roundTrip(a, []p.CheckoutDiff,
        \\[{"checkoutId":"k1","deviceId":"d1","cwd":"/w","patch":"diff --git a/x b/x\n+1\n",
        \\  "files":[{"path":"x","oldPath":"y","status":"renamed","additions":1,"deletions":0,"binary":false}],
        \\  "additions":1,"deletions":0,"truncated":false,"checksum":"abc","updatedAt":"2026-01-01T00:00:00Z"}]
    );
    _ = try roundTrip(a, p.WorkspaceGitStatusFrame,
        \\{"status":{"checkoutId":"k1","deviceId":"d1","revision":"r1","complete":true,
        \\ "files":[{"path":"a","oldPath":null,"index":"added","worktree":"unchanged"},
        \\ {"path":"b","oldPath":"c","index":"renamed","worktree":"typeChanged"}]}}
    );
    _ = try roundTrip(a, p.WorkspaceGitStatusFrame,
        \\{"status":null}
    );
    _ = try roundTrip(a, p.CheckoutChangeRequestStatus,
        \\{"checkoutId":"k1","deviceId":"d1","cwd":"/w","branch":"feat","changeRequest":{"provider":"github",
        \\ "number":42,"title":"Feat","url":"https://x/42","state":"open","baseRef":"main","headRef":"feat"},
        \\ "updatedAt":"2026-01-01T00:00:00Z"}
    );
    _ = try roundTrip(a, p.CheckoutFileDiffText,
        \\{"diffChecksum":"abc","oldText":"a","newText":"b","oldContentHash":"h1","newContentHash":"h2",
        \\ "binary":false,"truncated":false,"stale":true}
    );
    _ = try roundTrip(a, p.params.GetCheckoutFileDiffText,
        \\{"checkoutId":"k1","cwd":"/w","path":"x","mode":"branch","baseRef":"main","diffChecksum":"abc"}
    );
}

test "terminals" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try roundTrip(a, p.TerminalSession,
        \\{"id":"term-1","cwd":"/home/u","shell":"/bin/zsh"}
    );
    const data = try roundTrip(a, p.TerminalEvent,
        \\{"type":"data","seq":3,"data":"aGVsbG8K"}
    );
    const bytes = try data.decodeData(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello\n", bytes);
    const exit = try roundTrip(a, p.TerminalEvent,
        \\{"type":"exit","seq":4,"exitCode":130,"signal":"SIGINT"}
    );
    try testing.expectEqual(@as(i32, 130), exit.exit.exitCode);
    _ = try roundTrip(a, p.params.OpenTerminal,
        \\{"chatId":"c1","cols":80,"rows":24,"cwd":"~"}
    );
    _ = try roundTrip(a, p.params.SubscribeTerminal,
        \\{"terminalId":"term-1","afterSeq":2}
    );
    var buf: [16]u8 = undefined;
    const w = p.params.WriteTerminal.init("term-1", "ls\r", &buf);
    try testing.expectEqualStrings("bHMN", w.data);
    _ = try roundTrip(a, p.params.WriteTerminal,
        \\{"terminalId":"term-1","data":"bHMN"}
    );
    _ = try roundTrip(a, p.params.ResizeTerminal,
        \\{"terminalId":"term-1","cols":120,"rows":40}
    );
    _ = try roundTrip(a, p.params.TerminalId,
        \\{"terminalId":"term-1"}
    );
}

test "connectivity: open enum falls back to unknown" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try roundTrip(a, p.Connectivity,
        \\{"state":"connected","retryAtMs":0,"lastFailure":"x","chats":[{"chatId":"c1","syncState":"synced",
        \\ "connected":true,"deliveryLive":true,"pendingPushes":2}]}
    );
    try testing.expectEqual(p.ChatSyncState.synced, c.chats[0].syncState);
    const future = try json.parseFromSliceLeaky(p.ChatConnectivity, arena_state.allocator(),
        \\{"chatId":"c1","syncState":"quantumEntangled","connected":false,"someNewField":1}
    , .{ .ignore_unknown_fields = true });
    try testing.expectEqual(p.ChatSyncState.unknown, future.syncState);
}
