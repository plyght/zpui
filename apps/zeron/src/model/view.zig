//! Frontend-agnostic view logic — port of zeron `crates/proto/src/view.rs`
//! (plus `chat_indicator` / `Chat::unseen` from `entities.rs` and
//! `version_triple` from `lib.rs`): sort orders, staleness gating, sidebar
//! grouping, the boot gate, relative times, tool-chip text.
//!
//! Everything here is pure. Names mirror the Rust functions in camelCase.
//! Timestamps on the wire are RFC 3339 strings; every comparison here parses
//! them to instants (`time.zig`) like serde → `DateTime<Utc>` does, so
//! differently spelled equal instants order correctly. Parity with the Rust
//! implementation is checked by `view_parity_test.zig` against fixtures
//! dumped by `apps/zeron/scripts/view_parity.rs`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;
const protocol = @import("zeron_engine").protocol;
const time = @import("time.zig");

pub const Timestamp = time.Timestamp;
const Chat = protocol.Chat;
const Session = protocol.Session;
const Space = protocol.Space;
const AuthState = protocol.AuthState;
const WorkspaceScope = protocol.WorkspaceScope;
const ToolCall = protocol.ToolCall;

// ---------------------------------------------------------------------------
// Connection + status
// ---------------------------------------------------------------------------

/// Viewport ⇄ engine connection lifecycle.
pub const ConnectionStatus = union(enum) {
    connecting,
    ready,
    /// Error text (owned by whoever holds the status).
    failed: []const u8,

    pub fn eql(a: ConnectionStatus, b: ConnectionStatus) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .failed => |m| std.mem.eql(u8, m, b.failed),
            else => true,
        };
    }
};

/// What a chat's status dot / working indicator should show right now.
pub const Indicator = enum { none, working, awaiting_input, errored };

/// Display status for a chat row/tab (`zeron_proto::ChatIndicator`; tag
/// names are the serde wire names).
pub const ChatIndicator = enum {
    working,
    awaitingInput,
    errored,
    /// Finished running (or errored out) but not seen yet on any device.
    completed,
    idle,
};

/// A `working`/`awaitingInput` session older than this is treated as dead.
pub const session_stale_ms: i64 = 45_000;

/// Staleness-checked indicator for a session row.
pub fn effectiveIndicator(session: ?*const Session, now: Timestamp) Indicator {
    const s = session orelse return .none;
    return switch (s.status) {
        .idle => .none,
        .errored => .errored,
        .working, .awaitingInput => {
            const updated = time.parse(s.updatedAt) orelse Timestamp.epoch;
            const age_ms = now.millisSince(updated);
            if (age_ms > session_stale_ms) return .none;
            return if (s.status == .working) .working else .awaiting_input;
        },
    };
}

/// `Chat::unseen`: activity the user hasn't seen on any device.
pub fn chatUnseen(chat: *const Chat) bool {
    const msg = time.parseOpt(chat.lastMessageAt) orelse return false;
    const seen = time.parseOpt(chat.lastSeenAt) orelse return true;
    return msg.order(seen) == .gt;
}

/// `zeron_proto::chat_indicator`: `live` must already be staleness-gated.
pub fn chatIndicator(chat: *const Chat, live: ?*const Session) ChatIndicator {
    if (live) |s| switch (s.status) {
        .working => return .working,
        .awaitingInput => return .awaitingInput,
        .errored => if (chatUnseen(chat)) return .errored,
        .idle => {},
    };
    return if (chatUnseen(chat)) .completed else .idle;
}

/// Full display status for a chat row / tab dot.
pub fn displayStatus(chat: *const Chat, session: ?*const Session, now: Timestamp) ChatIndicator {
    const live = if (session) |s| (if (effectiveIndicator(s, now) != .none) s else null) else null;
    return chatIndicator(chat, live);
}

/// Attention bucket for the sidebar's Active list — lower is more urgent.
pub fn attentionRank(status: ChatIndicator) u8 {
    return switch (status) {
        .awaitingInput => 0,
        .errored => 1,
        .working => 2,
        .completed => 3,
        .idle => 4,
    };
}

// ---------------------------------------------------------------------------
// Sort orders
// ---------------------------------------------------------------------------

fn created(chat: *const Chat) Timestamp {
    return time.parse(chat.createdAt) orelse Timestamp.epoch;
}

fn recency(chat: *const Chat) Timestamp {
    return time.parseOpt(chat.lastMessageAt) orelse created(chat);
}

pub const ActiveRow = struct {
    status: ChatIndicator,
    chat: *const Chat,
};

/// Active-list order: pure recency (`lastMessageAt` desc, `createdAt`
/// fallback), id tiebreak. Status drives the dot, never the position.
pub fn sortActive(rows: []ActiveRow) void {
    std.sort.block(ActiveRow, rows, {}, struct {
        fn lt(_: void, a: ActiveRow, b: ActiveRow) bool {
            const o = recency(b.chat).order(recency(a.chat));
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.chat.id, b.chat.id) == .lt;
        }
    }.lt);
}

/// Session-tab order for a space: creation order, id tiebreak.
pub fn sortTabs(chats: []*const Chat) void {
    std.sort.block(*const Chat, chats, {}, struct {
        fn lt(_: void, a: *const Chat, b: *const Chat) bool {
            const o = created(a).order(created(b));
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
}

/// Spaces list order: creation order, id tiebreak.
pub fn sortSpaces(spaces: []Space) void {
    std.sort.block(Space, spaces, {}, struct {
        fn lt(_: void, a: Space, b: Space) bool {
            const ca = time.parse(a.createdAt) orelse Timestamp.epoch;
            const cb = time.parse(b.createdAt) orelse Timestamp.epoch;
            const o = ca.order(cb);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
}

/// Sidebar order: recency desc, then `createdAt` desc, then id.
pub fn sortChats(chats: []Chat) void {
    std.sort.block(Chat, chats, {}, struct {
        fn lt(_: void, a: Chat, b: Chat) bool {
            return chatsLessThan(&a, &b);
        }
    }.lt);
}

/// `sortChats`' comparator, for sorting pointers/indices the same way.
pub fn chatsLessThan(a: *const Chat, b: *const Chat) bool {
    var o = recency(b).order(recency(a));
    if (o != .eq) return o == .lt;
    o = created(b).order(created(a));
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

// ---------------------------------------------------------------------------
// Boot gate
// ---------------------------------------------------------------------------

/// The app gate (zeron's App.tsx phases).
pub const GatePhase = union(enum) {
    /// Booting / probing — splash covers this.
    loading,
    /// Engine unreachable and embedding failed (borrows the status' text).
    failed: []const u8,
    /// Engine up, but signed out — show the sign-in card.
    sign_in,
    /// Signed in but no organization selected — "Create your workspace".
    org_gate,
    /// Render the shell.
    ready,
};

/// Missing scope is treated as synced.
pub fn gatePhase(connection: ConnectionStatus, workspace_scope: ?WorkspaceScope, auth: ?*const AuthState) GatePhase {
    return switch (connection) {
        .connecting => .loading,
        .failed => |err| .{ .failed = err },
        .ready => switch (workspace_scope orelse .synced) {
            .local, .development => .ready,
            .synced => if (auth) |a| switch (a.*) {
                .needsOrganization => .org_gate,
                .signedIn => .ready,
                .signedOut => .sign_in,
            } else .sign_in,
        },
    };
}

/// Parse an `AuthStatus` frame tolerantly: the proto shape
/// (`{"state": "signedIn", ...}`) or the engine's own enum
/// (`{"_tag": "SignedIn", ...}`). Strings are borrowed from `value` or
/// allocated in `arena`.
pub fn parseAuthState(arena: Allocator, value: json.Value) ?AuthState {
    if (json.parseFromValueLeaky(AuthState, arena, value, .{ .ignore_unknown_fields = true })) |state| {
        return state;
    } else |_| {}
    if (value != .object) return null;
    const obj = value.object;
    const tag = obj.get("_tag") orelse return null;
    if (tag != .string) return null;
    if (std.mem.eql(u8, tag.string, "SignedOut")) return .signedOut;
    if (std.mem.eql(u8, tag.string, "NeedsOrganization")) {
        return .{ .needsOrganization = .{ .user = tagUser(obj) orelse return null } };
    }
    if (std.mem.eql(u8, tag.string, "SignedIn")) {
        return .{ .signedIn = .{ .user = tagUser(obj) orelse return null, .orgId = jsonStr(obj, "orgId") } };
    }
    return null;
}

fn jsonStr(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn tagUser(obj: json.ObjectMap) ?protocol.UserProfile {
    const u = obj.get("user") orelse return null;
    if (u != .object) return null;
    return .{
        .id = jsonStr(u.object, "id") orelse return null,
        .email = jsonStr(u.object, "email") orelse return null,
        .name = jsonStr(u.object, "name"),
    };
}

// ---------------------------------------------------------------------------
// Sidebar grouping
// ---------------------------------------------------------------------------

/// One grouped-by-project sidebar section.
pub const ChatGroup = struct {
    /// Borrowed from the chats (or a literal).
    label: []const u8,
    chats: std.ArrayList(*const Chat) = .empty,
};

pub const ChatGroups = struct {
    items: []ChatGroup,

    pub fn deinit(g: ChatGroups, gpa: Allocator) void {
        for (g.items) |*grp| grp.chats.deinit(gpa);
        gpa.free(g.items);
    }
};

/// Project label for a chat: the basename of its cwd, or "No project".
/// Returns a slice of `cwd` or a string literal (never allocates).
pub fn projectLabel(cwd_opt: ?[]const u8) []const u8 {
    const no_project = "No project";
    const cwd = trimUnicode(cwd_opt orelse return no_project);
    if (cwd.len == 0) return no_project;
    if (std.mem.eql(u8, cwd, "~") or std.mem.eql(u8, cwd, "~/")) return no_project;
    const trimmed = std.mem.trimEnd(u8, cwd, "/\\");
    if (fileName(trimmed)) |name| {
        if (name.len > 0) return name;
    }
    return cwd;
}

fn isSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

/// `std::path::Path::file_name` (Unix component rules; on Windows `\` is a
/// separator too): the last `Normal` component, `null` for `..`, a lone
/// `.`, a root, or an empty path.
fn fileName(path: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var first = true;
    const absolute = path.len > 0 and isSep(path[0]);
    var i: usize = 0;
    while (i < path.len) {
        while (i < path.len and isSep(path[i])) i += 1;
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and !isSep(path[i])) i += 1;
        const comp = path[start..i];
        if (std.mem.eql(u8, comp, ".")) {
            // CurDir survives only as the leading component of a relative path.
            if (first and !absolute) last = comp;
        } else last = comp;
        first = false;
    }
    const name = last orelse return null;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    return name;
}

/// Group chats by project label, preserving incoming order for groups (by
/// first appearance) and rows. Caller frees with `ChatGroups.deinit`.
pub fn groupChats(gpa: Allocator, chats: []const *const Chat) Allocator.Error!ChatGroups {
    var groups: std.ArrayList(ChatGroup) = .empty;
    errdefer {
        for (groups.items) |*g| g.chats.deinit(gpa);
        groups.deinit(gpa);
    }
    for (chats) |chat| {
        const label = projectLabel(chat.cwd);
        const group = for (groups.items) |*g| {
            if (std.mem.eql(u8, g.label, label)) break g;
        } else blk: {
            try groups.append(gpa, .{ .label = label });
            break :blk &groups.items[groups.items.len - 1];
        };
        try group.chats.append(gpa, chat);
    }
    return .{ .items = try groups.toOwnedSlice(gpa) };
}

/// Compact relative time ("now", "5m", "3h", "2d", "1w", "4mo", "2y").
/// Writes into `buf` (16 bytes is plenty).
pub fn formatTimeAgo(buf: []u8, then: Timestamp, now: Timestamp) []const u8 {
    const s = @max(now.secondsSince(then), 0);
    if (s < 60) return "now";
    const m = @divTrunc(s, 60);
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch unreachable;
    const h = @divTrunc(m, 60);
    if (h < 24) return std.fmt.bufPrint(buf, "{d}h", .{h}) catch unreachable;
    const d = @divTrunc(h, 24);
    if (d < 7) return std.fmt.bufPrint(buf, "{d}d", .{d}) catch unreachable;
    const w = @divTrunc(d, 7);
    if (w < 5) return std.fmt.bufPrint(buf, "{d}w", .{w}) catch unreachable;
    const mo = @divTrunc(d, 30);
    if (mo < 12) return std.fmt.bufPrint(buf, "{d}mo", .{mo}) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}y", .{@divTrunc(d, 365)}) catch unreachable;
}

/// Session-row sub-line, "project · branch"; null when both are missing.
pub fn chatLocation(gpa: Allocator, chat: *const Chat) Allocator.Error!?[]u8 {
    const project: ?[]const u8 = if (chat.cwd) |c|
        (if (trimUnicode(c).len > 0) projectLabel(trimUnicode(c)) else null)
    else
        null;
    const reference: ?[]const u8 = if (chat.branch) |b|
        (if (trimUnicode(b).len > 0) trimUnicode(b) else null)
    else
        null;
    if (project) |p| {
        if (reference) |r| return try std.fmt.allocPrint(gpa, "{s} · {s}", .{ p, r });
        return try gpa.dupe(u8, p);
    }
    if (reference) |r| return try gpa.dupe(u8, r);
    return null;
}

// ---------------------------------------------------------------------------
// Tool summaries
// ---------------------------------------------------------------------------

/// Rust `char::is_whitespace` (Unicode White_Space).
pub fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Rust `str::trim`.
pub fn trimUnicode(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[start .. start + n]) catch break;
        if (!isUnicodeWhitespace(cp)) break;
        start += n;
    }
    var end = s.len;
    while (end > start) {
        var b = end - 1;
        while (b > start and (s[b] & 0xC0) == 0x80) b -= 1;
        const cp = std.unicode.utf8Decode(s[b..end]) catch break;
        if (!isUnicodeWhitespace(cp)) break;
        end = b;
    }
    return s[start..end];
}

/// Collapse text onto ONE line: runs of Unicode whitespace become single
/// spaces, trimmed (`split_whitespace().join(" ")`).
pub fn singleLine(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len);
    var pending_space = false;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + n, text.len);
        const ws = if (std.unicode.utf8Decode(text[i..end])) |cp| isUnicodeWhitespace(cp) else |_| false;
        if (ws) {
            pending_space = out.items.len > 0;
        } else {
            if (pending_space) out.appendAssumeCapacity(' ');
            pending_space = false;
            out.appendSliceAssumeCapacity(text[i..end]);
        }
        i = end;
    }
    return out.toOwnedSlice(gpa);
}

pub const ToolChip = struct {
    label: []const u8,
    /// Owned by the caller's allocator.
    detail: []u8,
};

/// Per-kind chip label + one-line detail (zeron `describeTool`).
pub fn toolChipContent(gpa: Allocator, call: ToolCall) Allocator.Error!ToolChip {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const label: []const u8 = switch (call) {
        .exec => |c| blk: {
            try buf.appendSlice(gpa, c.command);
            break :blk "Run";
        },
        .readFile => |c| blk: {
            try buf.appendSlice(gpa, c.path);
            break :blk "Read";
        },
        .writeFile => |c| blk: {
            try buf.appendSlice(gpa, c.path);
            break :blk "Write";
        },
        .editFile => |c| blk: {
            try buf.appendSlice(gpa, c.path);
            break :blk "Edit";
        },
        .applyPatch => |c| blk: {
            try buf.appendSlice(gpa, c.path orelse "workspace");
            break :blk "Patch";
        },
        .search => |c| blk: {
            if (c.path) |p| try buf.print(gpa, "{s} in {s}", .{ c.pattern, p }) else try buf.appendSlice(gpa, c.pattern);
            break :blk "Search";
        },
        .glob => |c| blk: {
            try buf.appendSlice(gpa, c.pattern);
            break :blk "Glob";
        },
        .webFetch => |c| blk: {
            try buf.appendSlice(gpa, c.url);
            break :blk "Fetch";
        },
        .webSearch => |c| blk: {
            try buf.appendSlice(gpa, c.query);
            break :blk "Web";
        },
        .todo => |c| blk: {
            var done: usize = 0;
            for (c.items) |item| done += @intFromBool(item.done);
            try buf.print(gpa, "{d}/{d} done", .{ done, c.items.len });
            break :blk "Todo";
        },
        .mcp => |c| blk: {
            try buf.print(gpa, "{s} · {s}", .{ c.server, c.tool });
            break :blk "MCP";
        },
        .unknown => |c| blk: {
            if (std.mem.startsWith(u8, c.name, "Agent: ")) {
                try buf.appendSlice(gpa, c.name["Agent: ".len..]);
                break :blk "Agent";
            }
            if (std.mem.eql(u8, c.name, "Agent")) break :blk "Agent";
            try buf.appendSlice(gpa, c.name);
            break :blk "Tool";
        },
    };
    return .{ .label = label, .detail = try singleLine(gpa, buf.items) };
}

pub const ToolEntry = struct {
    call: ToolCall,
    is_error: bool = false,
};

/// The ToolGroup summary line — "Ran 3 commands · edited 2 files".
pub fn toolGroupSummary(gpa: Allocator, tools: []const ToolEntry) Allocator.Error![]u8 {
    var commands: usize = 0;
    var edited: std.ArrayList([]const u8) = .empty;
    defer edited.deinit(gpa);
    var reads: usize = 0;
    var searches: usize = 0;
    var fetches: usize = 0;
    var todos: usize = 0;
    var other: usize = 0;
    var failed: usize = 0;
    for (tools) |t| {
        if (t.is_error) failed += 1;
        switch (t.call) {
            .exec => commands += 1,
            .writeFile => |c| try addUnique(gpa, &edited, c.path),
            .editFile => |c| try addUnique(gpa, &edited, c.path),
            .applyPatch => |c| try addUnique(gpa, &edited, c.path orelse "patch"),
            .readFile => reads += 1,
            .search, .glob, .webSearch => searches += 1,
            .webFetch => fetches += 1,
            .todo => todos += 1,
            .mcp, .unknown => other += 1,
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var first = true;
    const Seg = struct {
        fn add(g: Allocator, o: *std.ArrayList(u8), f: *bool, comptime fmt: []const u8, args: anytype) !void {
            if (!f.*) try o.appendSlice(g, " · ");
            f.* = false;
            try o.print(g, fmt, args);
        }
        fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
            return if (n == 1) one else many;
        }
    };
    if (commands > 0) try Seg.add(gpa, &out, &first, "ran {d} {s}", .{ commands, Seg.plural(commands, "command", "commands") });
    if (edited.items.len > 0) try Seg.add(gpa, &out, &first, "edited {d} {s}", .{ edited.items.len, Seg.plural(edited.items.len, "file", "files") });
    if (reads > 0) try Seg.add(gpa, &out, &first, "read {d} {s}", .{ reads, Seg.plural(reads, "file", "files") });
    if (searches > 0) try Seg.add(gpa, &out, &first, "searched {d} {s}", .{ searches, Seg.plural(searches, "time", "times") });
    if (fetches > 0) try Seg.add(gpa, &out, &first, "fetched {d} {s}", .{ fetches, Seg.plural(fetches, "page", "pages") });
    if (todos > 0) try Seg.add(gpa, &out, &first, "updated todos", .{});
    if (other > 0) try Seg.add(gpa, &out, &first, "called {d} {s}", .{ other, Seg.plural(other, "tool", "tools") });
    if (first) try Seg.add(gpa, &out, &first, "{d} {s}", .{ tools.len, Seg.plural(tools.len, "tool", "tools") });
    if (failed > 0) try Seg.add(gpa, &out, &first, "{d} failed", .{failed});
    // Capitalize the first segment only (always ASCII here).
    if (out.items.len > 0) out.items[0] = std.ascii.toUpper(out.items[0]);
    return out.toOwnedSlice(gpa);
}

fn addUnique(gpa: Allocator, list: *std.ArrayList([]const u8), path: []const u8) !void {
    for (list.items) |p| if (std.mem.eql(u8, p, path)) return;
    try list.append(gpa, path);
}

/// The status-dot palette, as oklch triples (L, C, H°).
pub const dot = struct {
    /// Running. Pink, not amber.
    pub const working: [3]f32 = .{ 0.718, 0.202, 349.761 };
    /// Asking a question. Indigo.
    pub const awaiting: [3]f32 = .{ 0.673, 0.182, 276.935 };
    /// Errored. Red-400.
    pub const errored: [3]f32 = .{ 0.704, 0.191, 22.216 };
    /// Finished but unseen. Emerald.
    pub const completed: [3]f32 = .{ 0.765, 0.177, 163.223 };
};

// ---------------------------------------------------------------------------
// Checkout selection (new sessions)
// ---------------------------------------------------------------------------

/// `zeron_proto::RepoRef` (a `ListRefs` row).
pub const RepoRef = struct {
    name: []const u8,
    /// Checked out in the repo's MAIN folder right now.
    current: bool = false,
    /// Path of the linked worktree this branch is checked out in, if any.
    worktreePath: ?[]const u8 = null,
};

/// Where a new session runs.
pub const CheckoutKind = enum { local, new_worktree };

/// The resolved on-send checkout action (strings borrowed from the ref).
pub const CheckoutPlan = union(enum) {
    current_checkout: struct { branch: ?[]const u8 },
    reuse_worktree: struct { path: []const u8, branch: []const u8 },
    new_worktree: struct { base: ?[]const u8 },
};

pub fn checkoutPlan(kind: CheckoutKind, picked: ?*const RepoRef) CheckoutPlan {
    const name: ?[]const u8 = if (picked) |r| r.name else null;
    return switch (kind) {
        .new_worktree => .{ .new_worktree = .{ .base = name } },
        .local => if (picked) |r| (if (r.worktreePath) |path|
            CheckoutPlan{ .reuse_worktree = .{ .path = path, .branch = name orelse "" } }
        else
            CheckoutPlan{ .current_checkout = .{ .branch = name } }) else .{ .current_checkout = .{ .branch = null } },
    };
}

pub fn checkoutLabel(kind: CheckoutKind, picked: ?*const RepoRef) []const u8 {
    return switch (kind) {
        .new_worktree => "New worktree",
        .local => if (picked != null and picked.?.worktreePath != null) "Current worktree" else "Current checkout",
    };
}

// ---------------------------------------------------------------------------
// Entities helpers (proto `Space::display_name`, settings/devices.rs presence)
// ---------------------------------------------------------------------------

/// `Space::display_name`: name override, else basename(path), else the path.
pub fn spaceDisplayName(space: *const Space) []const u8 {
    if (space.name) |n| if (trimUnicode(n).len > 0) return n;
    const trimmed = std.mem.trimEnd(u8, space.path, "/\\");
    const cut = std.mem.findLastAny(u8, trimmed, "/\\");
    const base = if (cut) |c| trimmed[c + 1 ..] else trimmed;
    return if (base.len > 0) base else space.path;
}

/// Presence window for device rows (`DEVICE_ONLINE_WINDOW_SECS`).
pub const device_online_window_secs: i64 = 70;

/// Presence: last-seen within the online window (future timestamps count).
pub fn deviceOnline(last_seen: ?Timestamp, now: Timestamp) bool {
    const at = last_seen orelse return false;
    return now.secondsSince(at) <= device_online_window_secs;
}

/// Compact last-seen line ("just now", "5m ago", "never seen").
pub fn formatLastSeen(buf: []u8, last_seen: ?Timestamp, now: Timestamp) []const u8 {
    const at = last_seen orelse return "never seen";
    const secs = now.secondsSince(at);
    if (secs < 60) return "just now";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(secs, 60)}) catch unreachable;
    if (secs < 86_400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(secs, 3600)}) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(secs, 86_400)}) catch unreachable;
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

/// `zeron_proto::version_triple`: "0.2.12" (tolerating a `-suffix`/`+build`
/// tail on the last part) → comparable triple; null for anything else.
pub fn versionTriple(version: []const u8) ?[3]u64 {
    var parts = std.mem.splitScalar(u8, trimUnicode(version), '.');
    const major = parseU64(parts.next() orelse return null) orelse return null;
    const minor = parseU64(parts.next() orelse return null) orelse return null;
    const patch_raw = parts.rest();
    if (parts.index == null and patch_raw.len == 0) return null; // only two parts
    const cut = std.mem.findAny(u8, patch_raw, "-+") orelse patch_raw.len;
    const patch = parseU64(patch_raw[0..cut]) orelse return null;
    return .{ major, minor, patch };
}

/// Rust `u64::from_str`: optional `+`, then decimal digits only.
fn parseU64(s: []const u8) ?u64 {
    const digits = if (s.len > 0 and s[0] == '+') s[1..] else s;
    if (digits.len == 0) return null;
    var v: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return v;
}

/// True when `a >= b` lexicographically.
pub fn versionAtLeast(a: [3]u64, b: [3]u64) bool {
    for (a, b) |x, y| if (x != y) return x > y;
    return true;
}

// ---------------------------------------------------------------------------

test "gate phase basics" {
    const t = std.testing;
    const signed_out: AuthState = .signedOut;
    try t.expectEqual(GatePhase.ready, gatePhase(.ready, .local, &signed_out));
    try t.expectEqual(GatePhase.sign_in, gatePhase(.ready, .synced, &signed_out));
    try t.expectEqual(GatePhase.sign_in, gatePhase(.ready, null, null));
    try t.expectEqual(GatePhase.loading, gatePhase(.connecting, null, null));
}

test "project label and version triple" {
    const t = std.testing;
    try t.expectEqualStrings("zeron", projectLabel("/home/u/zeron/"));
    try t.expectEqualStrings("No project", projectLabel("~/"));
    try t.expectEqualStrings("/", projectLabel("/"));
    try t.expectEqual([3]u64{ 0, 2, 12 }, versionTriple("0.2.12-beta").?);
    try t.expect(versionTriple("1.2") == null);
    try t.expect(versionTriple("1.2.3.4") == null);
}
