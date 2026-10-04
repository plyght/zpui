//! The session row's context-menu helpers (zeron `shell.rs` chat menu,
//! `chat_copy_path`, `is_host_absolute_path` and `links.rs`
//! `workspace_locator` / `zeron_conversation_link` /
//! `harness_conversation_link`): what each "Copy ▸" row puts on the
//! clipboard. Pure, so the sidebar's handlers stay thin.

const std = @import("std");
const engine = @import("zeron_engine");

const protocol = engine.protocol;
const Chat = protocol.Chat;

/// Which page the chat context menu shows.
pub const Page = enum { root, copy };

/// Absolute on the HOST, whatever the viewer's OS: POSIX `/…`, UNC `\\…`,
/// or a drive path `C:\…` / `C:/…`.
pub fn isHostAbsolutePath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "\\\\")) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

/// `chat_copy_path`: the chat's working directory as the host spells it
/// (projectless `~` chats have none).
pub fn chatCopyPath(chat: *const Chat) ?[]const u8 {
    const cwd = std.mem.trim(u8, chat.cwd orelse return null, " \t\r\n");
    return if (isHostAbsolutePath(cwd)) cwd else null;
}

/// `encode_component`: unreserved bytes pass, everything else is `%XX`.
pub fn encodeComponent(out: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            try out.writeByte(b);
        } else try out.print("%{X:0>2}", .{b});
    }
}

/// `workspace_locator`: the first 16 hex chars of
/// `sha256("{Scope:?}\0{identity}")` — `user:{id}:org:{org|personal}` for a
/// synced/development workspace (signed in), `device:{id}` for a local one.
pub fn workspaceLocator(buf: *[16]u8, scope: ?protocol.WorkspaceScope, auth: ?protocol.AuthState, local_device_id: ?[]const u8) ?[]const u8 {
    const s = scope orelse return null;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(switch (s) {
        .synced => "Synced",
        .development => "Development",
        .local => "Local",
    });
    h.update("\x00");
    switch (s) {
        .synced, .development => {
            const a = auth orelse return null;
            if (a != .signedIn) return null;
            h.update("user:");
            h.update(a.signedIn.user.id);
            h.update(":org:");
            h.update(a.signedIn.orgId orelse "personal");
        },
        .local => {
            h.update("device:");
            h.update(local_device_id orelse return null);
        },
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    buf.* = hex;
    return buf;
}

/// `zeron://open/chat/{chat}?workspace={locator}`.
pub fn zeronConversationLink(gpa: std.mem.Allocator, chat_id: []const u8, workspace: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("zeron://open/chat/");
    try encodeComponent(&aw.writer, chat_id);
    try aw.writer.writeAll("?workspace=");
    try encodeComponent(&aw.writer, workspace);
    return aw.toOwnedSlice();
}

pub const HarnessLink = struct { label: []const u8, url: []u8 };

/// `harness_conversation_link`: Codex sessions open as `codex://threads/{id}`.
pub fn harnessConversationLink(gpa: std.mem.Allocator, chat: *const Chat) !?HarnessLink {
    const id = std.mem.trim(u8, chat.harnessSessionId orelse return null, " \t\r\n");
    if (id.len == 0) return null;
    const cfg = chat.config orelse return null;
    if (cfg.harness != .codex) return null;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("codex://threads/");
    try encodeComponent(&aw.writer, id);
    return .{ .label = "Codex conversation link", .url = try aw.toOwnedSlice() };
}

/// The chat's harness session id, when it has a non-blank one.
pub fn harnessSessionId(chat: *const Chat) ?[]const u8 {
    const id = chat.harnessSessionId orelse return null;
    return if (std.mem.trim(u8, id, " \t\r\n").len > 0) id else null;
}

const testing = std.testing;

test "host absolute paths across OSes" {
    try testing.expect(isHostAbsolutePath("/home/x"));
    try testing.expect(isHostAbsolutePath("\\\\server\\share"));
    try testing.expect(isHostAbsolutePath("C:\\work"));
    try testing.expect(isHostAbsolutePath("d:/work"));
    try testing.expect(!isHostAbsolutePath("~"));
    try testing.expect(!isHostAbsolutePath("rel/path"));
    var chat: Chat = .{ .id = "c", .deviceId = "d", .archived = false, .createdAt = "" };
    try testing.expect(chatCopyPath(&chat) == null);
    chat.cwd = "  /repo/wt  ";
    try testing.expectEqualStrings("/repo/wt", chatCopyPath(&chat).?);
}

test "conversation links match links.rs" {
    var buf: [16]u8 = undefined;
    // Same inputs as links.rs: sha256("Local\0device:dev-1")[..16].
    const loc = workspaceLocator(&buf, .local, null, "dev-1").?;
    var expect_h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("Local\x00device:dev-1", &expect_h, .{});
    const expect_hex = std.fmt.bytesToHex(expect_h, .lower);
    try testing.expectEqualStrings(expect_hex[0..16], loc);
    try testing.expect(workspaceLocator(&buf, .synced, null, null) == null);
    try testing.expect(workspaceLocator(&buf, null, null, "d") == null);
    const link = try zeronConversationLink(testing.allocator, "chat id/1", "abc");
    defer testing.allocator.free(link);
    try testing.expectEqualStrings("zeron://open/chat/chat%20id%2F1?workspace=abc", link);

    var chat: Chat = .{ .id = "c", .deviceId = "d", .archived = false, .createdAt = "", .harnessSessionId = "thr 1", .config = .{ .harness = .codex, .sandbox = .@"workspace-write" } };
    const h = (try harnessConversationLink(testing.allocator, &chat)).?;
    defer testing.allocator.free(h.url);
    try testing.expectEqualStrings("codex://threads/thr%201", h.url);
    chat.config = .{ .harness = .@"claude-code", .sandbox = .@"workspace-write" };
    try testing.expect((try harnessConversationLink(testing.allocator, &chat)) == null);
}
