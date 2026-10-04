//! Spawn chips as links (zeron `transcript.rs` "Open subagent",
//! `subagent_tab_title`, `strip_spawn_prefix`, `title_line`) and the
//! explorer's Subagents rows (`files/sections.rs` `subagent_rows`).
//!
//! A spawn chip with a stamped `subagentRef` opens that subagent doc's
//! transcript as a right-pane tab: the view emits `OpenSubagent` and the
//! shell hosts the surface. `frozen` (done / failed) reads the uploaded
//! blob first (`FetchToolBlob {chat}/{doc}`), a running one watches the doc.

const std = @import("std");
const engine = @import("zeron_engine");

const protocol = engine.protocol;
const ToolCall = protocol.ToolCall;

/// `TranscriptEvent::OpenSubagent` (strings borrowed for the emit).
pub const OpenSubagent = struct {
    chat_id: []const u8,
    doc_id: []const u8,
    title: []const u8,
    frozen: bool,
};

pub const subagent_title_max: usize = 40;

/// First non-blank line of `text`, trimmed, capped at `max` chars with `…`.
pub fn titleLine(buf: []u8, text: []const u8, max: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    const line = while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) break t;
    } else return null;
    var chars: usize = 0;
    var i: usize = 0;
    while (i < line.len and chars < max) : (chars += 1) i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
    const cut = @min(i, line.len);
    if (cut >= line.len) return line;
    const ell = "\u{2026}";
    if (cut + ell.len > buf.len) return line[0..cut];
    @memcpy(buf[0..cut], line[0..cut]);
    @memcpy(buf[cut..][0..ell.len], ell);
    return buf[0 .. cut + ell.len];
}

/// Drop a leading "Agent"/"Task" genus (word boundary only).
pub fn stripSpawnPrefix(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    for ([_][]const u8{ "agent", "task" }) |prefix| {
        if (t.len >= prefix.len and std.ascii.eqlIgnoreCase(t[0..prefix.len], prefix)) {
            const rest = t[prefix.len..];
            if (rest.len == 0) return "";
            if (rest[0] == ':' or std.ascii.isWhitespace(rest[0])) {
                return std.mem.trim(u8, std.mem.trimStart(u8, rest, ":"), " \t\r\n");
            }
        }
    }
    return t;
}

fn inputString(input: ?std.json.Value, key: []const u8) ?[]const u8 {
    const v = input orelse return null;
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

/// `subagent_tab_title`: the bare task ("audit the auth flow").
pub fn subagentTabTitle(buf: []u8, call: ToolCall) []const u8 {
    const name, const input = switch (call) {
        .unknown => |u| .{ u.name, u.input },
        .mcp => |m| .{ m.tool, m.input },
        else => return "Subagent",
    };
    const candidates = [_]?[]const u8{ name, inputString(input, "description"), inputString(input, "prompt") };
    for (candidates) |c| if (c) |text| {
        if (titleLine(buf, stripSpawnPrefix(text), subagent_title_max)) |t| return t;
    };
    return "Subagent";
}

/// Locate the tool part `part_id` of entry `entry` (spawn chip lookups).
pub fn findTool(entry: *const protocol.SessionMessageEntry, part_id: []const u8) ?*const protocol.MessagePart.Tool {
    for (entry.parts) |*p| switch (p.*) {
        .tool => |*t| if (std.mem.eql(u8, t.id, part_id)) return t,
        else => {},
    };
    return null;
}

pub fn isFrozen(status: ?protocol.SubagentStatus) bool {
    const s = status orelse return false;
    return s == .done or s == .failed;
}

/// The blob ref of a finished subagent's uploaded transcript: copied spawn
/// chips keep their original doc namespace (`{source}--sub--…`).
pub fn blobRef(buf: []u8, chat_id: []const u8, doc_id: []const u8) []const u8 {
    const source = if (std.mem.indexOf(u8, doc_id, "--sub--")) |i| doc_id[0..i] else chat_id;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ source, doc_id }) catch doc_id;
}

/// One explorer Subagents row (`SubagentRow`); strings borrow the entries.
pub const Row = struct {
    doc_id: []const u8,
    title: []const u8,
    status: ?protocol.SubagentStatus,
    spawned_at: i64,
};

/// `subagent_rows`: one row per stamped spawn chip in `entries` (a steered
/// subagent updates in place); running ones first (longest-running leading),
/// then settled ones most recently updated first. Titles go to `arena`.
/// `src` is anything with `len()` and `entry(i) *const SessionMessageEntry`
/// (a `TranscriptStore`, or `Entries` over a slice).
pub fn subagentRows(arena: std.mem.Allocator, src: anytype) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    for (0..src.len()) |ei| {
        const e = src.entry(ei);
        for (e.parts) |*p| switch (p.*) {
            .tool => |*t| {
                const doc = t.subagentRef orelse continue;
                if (!t.call.isSubagentSpawn()) continue;
                var buf: [256]u8 = undefined;
                const title = try arena.dupe(u8, subagentTabTitle(&buf, t.call));
                const row: Row = .{ .doc_id = doc, .title = title, .status = t.subagentStatus, .spawned_at = e.createdAt };
                // A reopened (steered) subagent updates its row in place.
                const existing = for (rows.items) |*r| {
                    if (std.mem.eql(u8, r.doc_id, doc)) break r;
                } else null;
                if (existing) |r| r.* = row else try rows.append(arena, row);
            },
            else => {},
        };
    }
    std.mem.reverse(Row, rows.items);
    // Newest first (stable over the reversed spawn order).
    std.sort.insertion(Row, rows.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.spawned_at > b.spawned_at;
        }
    }.lt);
    var running: std.ArrayList(Row) = .empty;
    var settled: std.ArrayList(Row) = .empty;
    for (rows.items) |r| try (if (r.status == .running) &running else &settled).append(arena, r);
    std.mem.reverse(Row, running.items);
    std.sort.insertion(Row, running.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.spawned_at < b.spawned_at;
        }
    }.lt);
    try running.appendSlice(arena, settled.items);
    return running.items;
}

/// A plain entry slice as a `subagentRows` source.
pub const Entries = struct {
    items: []const protocol.SessionMessageEntry,
    pub fn len(self: Entries) usize {
        return self.items.len;
    }
    pub fn entry(self: Entries, i: usize) *const protocol.SessionMessageEntry {
        return &self.items[i];
    }
};

const testing = std.testing;

test "subagent tab titles strip the genus" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("scan repo", subagentTabTitle(&buf, .{ .unknown = .{ .name = "Agent: scan repo" } }));
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(testing.allocator);
    try obj.put(testing.allocator, "description", .{ .string = "Agent: audit the auth flow" });
    try obj.put(testing.allocator, "prompt", .{ .string = "very long" });
    try testing.expectEqualStrings("audit the auth flow", subagentTabTitle(&buf, .{ .unknown = .{ .name = "Task", .input = .{ .object = obj } } }));
    try testing.expectEqualStrings("Taskmaster", subagentTabTitle(&buf, .{ .unknown = .{ .name = "Taskmaster" } }));
    try testing.expectEqualStrings("Subagent", subagentTabTitle(&buf, .{ .unknown = .{ .name = "Agent" } }));
    try testing.expectEqualStrings("Subagent", subagentTabTitle(&buf, .{ .exec = .{ .command = "ls" } }));
    const long = "Agent: " ++ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    const t = subagentTabTitle(&buf, .{ .unknown = .{ .name = long } });
    try testing.expect(std.mem.endsWith(u8, t, "\u{2026}"));
    try testing.expectEqual(@as(usize, 40 + 3), t.len);
}

test "blob refs keep the source namespace" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("c1/d1", blobRef(&buf, "c1", "d1"));
    try testing.expectEqualStrings("src/src--sub--x", blobRef(&buf, "c1", "src--sub--x"));
}

test "subagent rows: running first oldest-first, then settled newest-first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mk = struct {
        fn part(id: []const u8, doc: []const u8, status: protocol.SubagentStatus) protocol.MessagePart {
            return .{ .tool = .{ .id = id, .call = .{ .unknown = .{ .name = "Agent: job" } }, .subagentRef = doc, .subagentStatus = status } };
        }
    };
    var p1 = [_]protocol.MessagePart{ mk.part("t1", "d1", .done), mk.part("t2", "d2", .running) };
    var p2 = [_]protocol.MessagePart{ mk.part("t3", "d3", .running), mk.part("t4", "d4", .failed), .{ .tool = .{ .id = "x", .call = .{ .exec = .{ .command = "ls" } }, .subagentRef = "bogus" } } };
    const entries = [_]protocol.SessionMessageEntry{
        .{ .id = "e1", .role = .assistant, .parts = &p1, .createdAt = 100, .deviceId = "d" },
        .{ .id = "e2", .role = .assistant, .parts = &p2, .createdAt = 200, .deviceId = "d" },
    };
    const rows = try subagentRows(a, Entries{ .items = &entries });
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("d2", rows[0].doc_id);
    try testing.expectEqualStrings("d3", rows[1].doc_id);
    try testing.expectEqualStrings("d4", rows[2].doc_id);
    try testing.expectEqualStrings("d1", rows[3].doc_id);
}
