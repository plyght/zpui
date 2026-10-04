//! Workspace file RPC shapes (zeron `crates/proto/src/entities.rs`:
//! `ListWorkspaceDirectoryRequest` … `WorkspaceMutationOutcome`), kept next
//! to the Files surface so `engine/protocol.zig` stays untouched. Field
//! names are the wire's camelCase; enums use the wire spellings.

const std = @import("std");
const engine = @import("zeron_engine");

pub const GitFileStatus = engine.protocol.GitFileStatus;
pub const GitFileState = engine.protocol.GitFileState;
pub const CheckoutGitStatus = engine.protocol.CheckoutGitStatus;
pub const WorkspaceGitStatusFrame = engine.protocol.WorkspaceGitStatusFrame;

pub const EntryKind = enum { file, directory, symlink };

pub const MutationCapabilities = struct {
    moveEntry: bool = false,
    deleteEntry: bool = false,
};

pub const Entry = struct {
    mutationRevision: ?[]const u8 = null,
    path: []const u8,
    name: []const u8,
    kind: EntryKind,
    size: ?u64 = null,
    modifiedAt: ?[]const u8 = null,
    ignored: bool = false,
    readOnly: bool = false,
};

pub const DirectoryPage = struct {
    checkoutId: ?[]const u8 = null,
    mutationCapabilities: ?MutationCapabilities = null,
    directory: []const u8,
    entries: []const Entry,
    nextCursor: ?[]const u8 = null,
    truncated: bool = false,
};

pub const SearchMatch = struct {
    path: []const u8,
    name: []const u8,
    kind: EntryKind,
    score: i64 = 0,
};

pub const TextEncoding = enum { utf8, utf8Bom, binary, unsupported };
pub const LineEnding = enum { lf, crlf, mixed, none };
pub const ReadOnlyReason = enum {
    binary,
    unsupportedEncoding,
    mixedLineEndings,
    symlink,
    tooLarge,
    permissionDenied,
    notRegularFile,
    outsideWorkspace,
};

pub const FileText = struct {
    checkoutId: []const u8 = "",
    path: []const u8,
    text: ?[]const u8 = null,
    contentHash: ?[]const u8 = null,
    size: u64 = 0,
    modifiedAt: ?[]const u8 = null,
    encoding: TextEncoding = .utf8,
    lineEnding: ?LineEnding = null,
    readOnlyReason: ?ReadOnlyReason = null,
    truncated: bool = false,
};

pub const WritableEncoding = enum { utf8, utf8Bom };
pub const WritableLineEnding = enum { lf, crlf };

pub const ConflictReason = enum { changed, deleted, replaced, notRegularFile };

pub const WriteResult = struct {
    path: []const u8,
    contentHash: []const u8,
    size: u64 = 0,
    modifiedAt: ?[]const u8 = null,
};

/// `WriteWorkspaceFileOutcome` (tagged by `status`).
pub const WriteOutcome = union(enum) {
    written: WriteResult,
    conflict: struct {
        reason: ConflictReason,
        currentContentHash: ?[]const u8 = null,
    },

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !WriteOutcome {
        if (v != .object) return error.UnexpectedToken;
        const status = v.object.get("status") orelse return error.MissingField;
        if (status != .string) return error.UnexpectedToken;
        if (std.mem.eql(u8, status.string, "written")) {
            const file = v.object.get("file") orelse return error.MissingField;
            return .{ .written = try std.json.parseFromValueLeaky(WriteResult, a, file, o) };
        }
        if (std.mem.eql(u8, status.string, "conflict")) {
            const reason_v = v.object.get("reason") orelse return error.MissingField;
            const reason = try std.json.parseFromValueLeaky(ConflictReason, a, reason_v, o);
            var hash: ?[]const u8 = null;
            if (v.object.get("currentContentHash")) |h| if (h == .string) {
                hash = h.string;
            };
            return .{ .conflict = .{ .reason = reason, .currentContentHash = hash } };
        }
        return error.UnexpectedToken;
    }
};

pub const ChangeKind = enum { created, modified, removed, renamed };

pub const FileChange = struct {
    operationId: ?[]const u8 = null,
    kind: ChangeKind,
    path: []const u8,
    oldPath: ?[]const u8 = null,
};

pub const FileChanges = struct {
    sequence: u64 = 0,
    resyncRequired: bool = false,
    changes: []const FileChange = &.{},
};

pub const MutationRejection = enum {
    invalidPath,
    workspaceChanged,
    sourceMissing,
    sourceChanged,
    destinationExists,
    invalidDestination,
    permissionDenied,
    unsupported,
    busy,
    partialFailure,
};

/// `WorkspaceMutationOutcome` (tagged by `status`).
pub const MutationOutcome = union(enum) {
    applied: struct { change: ?FileChange = null },
    rejected: struct { reason: ?MutationRejection = null, message: []const u8 = "" },

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !MutationOutcome {
        if (v != .object) return error.UnexpectedToken;
        const status = v.object.get("status") orelse return error.MissingField;
        if (status != .string) return error.UnexpectedToken;
        if (std.mem.eql(u8, status.string, "applied")) {
            var change: ?FileChange = null;
            if (v.object.get("change")) |c| change = std.json.parseFromValueLeaky(FileChange, a, c, o) catch null;
            return .{ .applied = .{ .change = change } };
        }
        var msg: []const u8 = "";
        if (v.object.get("message")) |m| if (m == .string) {
            msg = m.string;
        };
        var reason: ?MutationRejection = null;
        if (v.object.get("reason")) |r| reason = std.json.parseFromValueLeaky(MutationRejection, a, r, o) catch null;
        return .{ .rejected = .{ .reason = reason, .message = msg } };
    }
};

/// Request params (`WorkspaceTarget` is flattened into each).
/// `MAX_WORKSPACE_IMAGE_BYTES` / `WORKSPACE_IMAGE_CHUNK_BYTES`.
pub const max_workspace_image_bytes: usize = 8 * 1024 * 1024;
pub const workspace_image_chunk_bytes: usize = 384 * 1024;

/// `WorkspaceImageChunk`: base64 `data` from the request offset to `nextOffset`.
pub const ImageChunk = struct {
    checkoutId: []const u8,
    contentHash: []const u8,
    mimeType: []const u8,
    data: []const u8,
    nextOffset: u64,
    size: u64,
    done: bool,
};

pub const params = struct {
    /// `ReadWorkspaceImageRequest`.
    pub const ReadImage = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        path: []const u8,
        expectedCheckoutId: []const u8,
        offset: u64 = 0,
        expectedContentHash: ?[]const u8 = null,
    };
    pub const ListDirectory = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        directory: []const u8,
        includeIgnored: bool = false,
        cursor: ?[]const u8 = null,
    };
    pub const Search = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        query: []const u8,
        includeIgnored: bool = false,
        limit: ?u16 = null,
    };
    pub const Read = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        path: []const u8,
    };
    pub const Write = struct {
        expectedCheckoutId: []const u8,
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        path: []const u8,
        text: []const u8,
        expectedContentHash: []const u8,
        encoding: WritableEncoding,
        lineEnding: WritableLineEnding,
    };
    pub const Watch = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
    };
    pub const Move = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        operationId: []const u8,
        expectedCheckoutId: []const u8,
        sourcePath: []const u8,
        destinationPath: []const u8,
        expectedSourceRevision: []const u8,
        expectedKind: EntryKind,
    };
    pub const Delete = struct {
        chatId: ?[]const u8 = null,
        spaceId: ?[]const u8 = null,
        checkoutPath: ?[]const u8 = null,
        operationId: []const u8,
        expectedCheckoutId: []const u8,
        path: []const u8,
        expectedSourceRevision: []const u8,
        expectedKind: EntryKind,
        recursive: bool = false,
    };
};

/// Engine `MAX_SEARCH_RESULTS`.
pub const max_search_results: usize = 200;
/// Engine `DIRECTORY_PAGE_SIZE`.
pub const directory_page_size: usize = 500;

/// Engine `workspace_search_score` (higher is better; null = no match).
pub fn searchScore(name_in: []const u8, path_in: []const u8, query_lower: []const u8) ?i64 {
    if (query_lower.len == 0) return 0;
    var name_buf: [512]u8 = undefined;
    var path_buf: [2048]u8 = undefined;
    if (name_in.len > name_buf.len or path_in.len > path_buf.len) return null;
    const name = std.ascii.lowerString(&name_buf, name_in);
    const path = std.ascii.lowerString(&path_buf, path_in);
    const nl: i64 = @intCast(name.len);
    const pl: i64 = @intCast(path.len);
    if (std.mem.eql(u8, name, query_lower)) return 10_000;
    if (std.mem.startsWith(u8, name, query_lower)) return 8_000 - nl;
    if (std.mem.indexOf(u8, name, query_lower)) |i| return 6_000 - @as(i64, @intCast(i)) - nl;
    if (std.mem.indexOf(u8, path, query_lower)) |i| return 4_000 - @as(i64, @intCast(i)) - pl;
    var qi: usize = 0;
    var gaps: i64 = 0;
    for (path) |ch| {
        if (ch == query_lower[qi]) {
            qi += 1;
            if (qi == query_lower.len) return 2_000 - gaps - pl;
        } else gaps += 1;
    }
    return null;
}

pub fn lessThanMatch(_: void, a: SearchMatch, b: SearchMatch) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.ascii.lessThanIgnoreCase(a.path, b.path);
}

test "search score ordering matches the engine" {
    try std.testing.expectEqual(@as(?i64, 10_000), searchScore("main.rs", "src/main.rs", "main.rs"));
    try std.testing.expect(searchScore("stream.rs", "src/stream.rs", "str").? > searchScore("config.rs", "src/config.rs", "cfg").?);
    try std.testing.expect(searchScore("lib.rs", "src/lib.rs", "zzz") == null);
}
