//! Client-side transcript state for `WatchDocMessages`: applies reset/delta
//! frames exactly like `zeron_doc::apply_transcript_frame`
//! (crates/doc/src/transcript_delta.rs), including the `count`/`len` desync
//! tripwires. On `error.Desync` the state is unreliable: drop the
//! subscription and resubscribe to get a fresh `reset` (what the Rust UI does).
//!
//! Each row owns its entry in a private arena (deep-copied out of the frame's
//! payload arena), so frames can be freed right after `apply`. Streaming text
//! appends grow part buffers geometrically inside the row arena; replacing or
//! removing a row frees its arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const protocol = @import("protocol.zig");

const SessionMessageEntry = protocol.SessionMessageEntry;
const TranscriptFrame = protocol.TranscriptFrame;

pub const DesyncReason = enum {
    missing_anchor,
    missing_append_entry,
    missing_append_part,
    append_length_mismatch,
    count_mismatch,
};

/// Why the last `apply` failed (for logging).
pub const Desync = struct {
    reason: DesyncReason,
    /// Observed length (append/count mismatches).
    have: usize = 0,
    /// Length the frame expected.
    expected: usize = 0,
};

pub const Transcript = struct {
    gpa: Allocator,
    rows: std.ArrayList(Row) = .empty,
    /// Latest host context snapshot from `TranscriptUpdate.contextUsage`.
    context_usage: ?protocol.ContextUsage = null,
    last_desync: ?Desync = null,

    pub const Row = struct {
        arena: *std.heap.ArenaAllocator,
        entry: SessionMessageEntry,
        /// Per part: capacity of a growable text buffer at the part's text
        /// pointer, or 0 if the text is not (yet) in a growable buffer.
        caps: []usize,

        fn deinit(r: Row, gpa: Allocator) void {
            r.arena.deinit();
            gpa.destroy(r.arena);
        }
    };

    pub const Error = error{Desync} || Allocator.Error;

    pub fn init(gpa: Allocator) Transcript {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Transcript) void {
        t.clear();
        t.rows.deinit(t.gpa);
    }

    pub fn clear(t: *Transcript) void {
        for (t.rows.items) |r| r.deinit(t.gpa);
        t.rows.clearRetainingCapacity();
    }

    pub fn len(t: *const Transcript) usize {
        return t.rows.items.len;
    }

    pub fn entry(t: *const Transcript, index: usize) *const SessionMessageEntry {
        return &t.rows.items[index].entry;
    }

    /// Apply a full `WatchDocMessages` item.
    pub fn applyUpdate(t: *Transcript, update: protocol.TranscriptUpdate) Error!void {
        try t.apply(update.frame);
        if (update.contextUsage) |cu| t.context_usage = cu;
    }

    /// Apply one frame in place (`apply_transcript_frame`).
    pub fn apply(t: *Transcript, frame: TranscriptFrame) Error!void {
        t.last_desync = null;
        switch (frame) {
            .reset => |entries| {
                t.clear();
                try t.rows.ensureTotalCapacity(t.gpa, entries.len);
                for (entries) |e| t.rows.appendAssumeCapacity(try t.ownRow(e));
            },
            .delta => |d| {
                for (d.remove) |gone| {
                    var i: usize = 0;
                    while (i < t.rows.items.len) {
                        if (std.mem.eql(u8, t.rows.items[i].entry.id, gone)) {
                            t.rows.orderedRemove(i).deinit(t.gpa);
                        } else i += 1;
                    }
                }
                for (d.upsert) |u| {
                    if (t.find(u.entry.id)) |existing| t.rows.orderedRemove(existing).deinit(t.gpa);
                    const at = if (u.after) |anchor|
                        (t.find(anchor) orelse return t.fail(.{ .reason = .missing_anchor })) + 1
                    else
                        0;
                    const row = try t.ownRow(u.entry);
                    t.rows.insert(t.gpa, at, row) catch |err| {
                        row.deinit(t.gpa);
                        return err;
                    };
                }
                for (d.append) |a| {
                    const ri = t.findFromEnd(a.entry) orelse return t.fail(.{ .reason = .missing_append_entry });
                    const row = &t.rows.items[ri];
                    const pi = for (row.entry.parts, 0..) |*p, i| {
                        if (p.textBody() != null and std.mem.eql(u8, p.id(), a.part)) break i;
                    } else return t.fail(.{ .reason = .missing_append_part });
                    const body = row.entry.parts[pi].textBody().?;
                    try appendText(row, pi, body, a.text);
                    if (body.len != a.len) return t.fail(.{
                        .reason = .append_length_mismatch,
                        .have = body.len,
                        .expected = a.len,
                    });
                }
                if (t.rows.items.len != d.count) return t.fail(.{
                    .reason = .count_mismatch,
                    .have = t.rows.items.len,
                    .expected = d.count,
                });
            },
        }
    }

    fn fail(t: *Transcript, d: Desync) error{Desync} {
        t.last_desync = d;
        return error.Desync;
    }

    fn find(t: *const Transcript, id: []const u8) ?usize {
        for (t.rows.items, 0..) |r, i| if (std.mem.eql(u8, r.entry.id, id)) return i;
        return null;
    }

    /// Appends target the live (last) rows; search backwards.
    fn findFromEnd(t: *const Transcript, id: []const u8) ?usize {
        var i = t.rows.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, t.rows.items[i].entry.id, id)) return i;
        }
        return null;
    }

    /// Deep-copy `e` into a fresh row arena (via a JSON round trip, which
    /// handles every nested union/optional/`Value` uniformly).
    fn ownRow(t: *Transcript, e: SessionMessageEntry) Error!Row {
        const arena = try t.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(t.gpa);
        errdefer {
            arena.deinit();
            t.gpa.destroy(arena);
        }
        const a = arena.allocator();
        const bytes = json.Stringify.valueAlloc(t.gpa, e, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        defer t.gpa.free(bytes);
        const copy = json.parseFromSliceLeaky(SessionMessageEntry, a, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // we just serialized it
        };
        const caps = try a.alloc(usize, copy.parts.len);
        @memset(caps, 0);
        return .{ .arena = arena, .entry = copy, .caps = caps };
    }
};

fn appendText(row: *Transcript.Row, part_index: usize, body: *[]const u8, text: []const u8) Allocator.Error!void {
    if (text.len == 0) return;
    const old = body.*;
    const new_len = old.len + text.len;
    const cap = row.caps[part_index];
    if (cap >= new_len) {
        // The buffer is ours (allocated below); extend in place.
        const buf: [*]u8 = @constCast(old.ptr);
        @memcpy(buf[old.len..new_len], text);
        body.* = buf[0..new_len];
        return;
    }
    const new_cap = @max(new_len, old.len * 2, 64);
    const buf = try row.arena.allocator().alloc(u8, new_cap);
    @memcpy(buf[0..old.len], old);
    @memcpy(buf[old.len..new_len], text);
    body.* = buf[0..new_len];
    row.caps[part_index] = new_cap;
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseUpdate(arena: Allocator, text: []const u8) !protocol.TranscriptUpdate {
    return json.parseFromSliceLeaky(protocol.TranscriptUpdate, arena, text, .{ .ignore_unknown_fields = true });
}

fn expectTexts(t: *const Transcript, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, t.len());
    for (expected, 0..) |want, i| {
        var p = t.entry(i).parts[0];
        try testing.expectEqualStrings(want, p.textBody().?.*);
    }
}

inline fn entryJson(comptime id: []const u8, comptime text: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"role\":\"assistant\",\"parts\":[{\"kind\":\"text\",\"id\":\"t0\",\"text\":\"" ++
        text ++ "\"}],\"createdAt\":0,\"deviceId\":\"dev\"}";
}

test "reset, append (streaming hot path), upsert, remove, mid insert" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: Transcript = .init(testing.allocator);
    defer t.deinit();

    try t.applyUpdate(try parseUpdate(arena, "{\"reset\":[" ++ entryJson("a", "prompt") ++ "," ++ entryJson("b", "stream") ++
        "],\"contextUsage\":{\"tokens\":10,\"window\":100}}"));
    try expectTexts(&t, &.{ "prompt", "stream" });
    try testing.expectEqual(@as(?f64, 0.1), t.context_usage.?.fraction());

    // Many appends exercise in-place growth.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, "stream");
    for (0..50) |_| {
        try expected.appendSlice(testing.allocator, "ing…");
        var buf: [256]u8 = undefined;
        const frame = try std.fmt.bufPrint(&buf, "{{\"append\":[{{\"entry\":\"b\",\"part\":\"t0\",\"text\":\"ing…\",\"len\":{d}}}],\"count\":2}}", .{expected.items.len});
        try t.applyUpdate(try parseUpdate(arena, frame));
    }
    try expectTexts(&t, &.{ "prompt", expected.items });

    // Non-prefix rewrite re-sends the entry.
    try t.applyUpdate(try parseUpdate(arena, "{\"upsert\":[{\"after\":\"a\",\"entry\":" ++ entryJson("b", "final") ++ "}],\"count\":2}"));
    try expectTexts(&t, &.{ "prompt", "final" });

    // Remove a, then a remote merge lands x at the head and c after b.
    try t.applyUpdate(try parseUpdate(arena, "{\"remove\":[\"a\"],\"upsert\":[{\"after\":null,\"entry\":" ++ entryJson("x", "1") ++
        "},{\"after\":\"b\",\"entry\":" ++ entryJson("c", "3") ++ "}],\"count\":3}"));
    try expectTexts(&t, &.{ "1", "final", "3" });
    try testing.expectEqualStrings("x", t.entry(0).id);
}

test "append length mismatch is a desync" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: Transcript = .init(testing.allocator);
    defer t.deinit();
    try t.apply((try parseUpdate(arena, "{\"reset\":[" ++ entryJson("a", "hello") ++ "]}")).frame);
    try testing.expectError(error.Desync, t.apply((try parseUpdate(arena, "{\"append\":[{\"entry\":\"a\",\"part\":\"t0\",\"text\":\"x\",\"len\":99}],\"count\":1}")).frame));
    try testing.expectEqual(DesyncReason.append_length_mismatch, t.last_desync.?.reason);
    try testing.expectEqual(@as(usize, 6), t.last_desync.?.have);
    try testing.expectEqual(@as(usize, 99), t.last_desync.?.expected);
}

test "count mismatch, missing anchor, missing entry/part are desyncs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: Transcript = .init(testing.allocator);
    defer t.deinit();
    const reset = (try parseUpdate(arena, "{\"reset\":[" ++ entryJson("a", "hello") ++ "]}")).frame;

    try t.apply(reset);
    try testing.expectError(error.Desync, t.apply((try parseUpdate(arena, "{\"count\":5}")).frame));
    try testing.expectEqual(DesyncReason.count_mismatch, t.last_desync.?.reason);

    try t.apply(reset);
    try testing.expectError(error.Desync, t.apply((try parseUpdate(arena, "{\"upsert\":[{\"after\":\"missing\",\"entry\":" ++
        entryJson("x", "1") ++ "}],\"count\":2}")).frame));
    try testing.expectEqual(DesyncReason.missing_anchor, t.last_desync.?.reason);

    try t.apply(reset);
    try testing.expectError(error.Desync, t.apply((try parseUpdate(arena, "{\"append\":[{\"entry\":\"zz\",\"part\":\"t0\",\"text\":\"x\",\"len\":1}],\"count\":1}")).frame));
    try testing.expectEqual(DesyncReason.missing_append_entry, t.last_desync.?.reason);

    try t.apply(reset);
    try testing.expectError(error.Desync, t.apply((try parseUpdate(arena, "{\"append\":[{\"entry\":\"a\",\"part\":\"nope\",\"text\":\"x\",\"len\":6}],\"count\":1}")).frame));
    try testing.expectEqual(DesyncReason.missing_append_part, t.last_desync.?.reason);

    // A fresh reset recovers.
    try t.apply(reset);
    try expectTexts(&t, &.{"hello"});
}

test "reasoning parts take appends; tool parts do not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: Transcript = .init(testing.allocator);
    defer t.deinit();
    try t.apply((try parseUpdate(arena,
        \\{"reset":[{"id":"b","role":"assistant","createdAt":1,"deviceId":"d","parts":[
        \\  {"kind":"reasoning","id":"r0","text":"thinking"},
        \\  {"kind":"tool","id":"k1","call":{"kind":"exec","command":"ls"}}]}]}
    )).frame);
    try t.apply((try parseUpdate(arena,
        \\{"append":[{"entry":"b","part":"r0","text":" more","len":13}],"count":1}
    )).frame);
    var p = t.entry(0).parts[0];
    try testing.expectEqualStrings("thinking more", p.textBody().?.*);
    try testing.expectError(error.Desync, t.apply((try parseUpdate(arena,
        \\{"append":[{"entry":"b","part":"k1","text":"x","len":1}],"count":1}
    )).frame));
}

test "multi-byte UTF-8: len counts bytes like Rust String::len" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: Transcript = .init(testing.allocator);
    defer t.deinit();
    try t.apply((try parseUpdate(arena, "{\"reset\":[" ++ entryJson("a", "h") ++ "]}")).frame);
    // "é" is 2 bytes; "…" is 3.
    try t.apply((try parseUpdate(arena, "{\"append\":[{\"entry\":\"a\",\"part\":\"t0\",\"text\":\"é…\",\"len\":6}],\"count\":1}")).frame);
    try expectTexts(&t, &.{"hé…"});
}
