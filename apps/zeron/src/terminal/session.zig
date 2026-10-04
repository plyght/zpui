//! The engine-facing side of a terminal tab, ported from zeron's
//! `crates/ui/src/terminal/panel.rs` + `view.rs`:
//!
//! - `DataStream`: applies `SubscribeTerminal` events (`data{seq, base64}` /
//!   `exit{seq, exitCode}`) to an emulator in sequence order, remembering
//!   `last_seq` for `afterSeq` on resubscribe and dropping replayed frames;
//! - `InputCoalescer`: the 12 ms keyboard batching buffer;
//! - `exitMessage`, `shellTitle`: the `[process exited N]` trailer and tab
//!   titles.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emulator = @import("Emulator.zig");

/// Keyboard input coalescing window before a `WriteTerminal` flush.
pub const coalesce_ms: u64 = 12;
/// Debounce for `ResizeTerminal` after viewport-driven size changes.
pub const resize_debounce_ms: u64 = 80;

/// A `SubscribeTerminal` stream item (engine `TerminalEvent`).
pub const Event = union(enum) {
    data: struct { seq: u64, data: []const u8 },
    exit: struct { seq: u64, exit_code: i32 },

    /// Adapt `zeron_engine.protocol.TerminalEvent` (or any union with the
    /// same `data{seq,data}` / `exit{seq,exitCode}` shape).
    pub fn fromProtocol(ev: anytype) Event {
        return switch (ev) {
            .data => |d| .{ .data = .{ .seq = d.seq, .data = d.data } },
            .exit => |e| .{ .exit = .{ .seq = e.seq, .exit_code = e.exitCode } },
        };
    }

    pub fn seq(self: Event) u64 {
        return switch (self) {
            inline else => |v| v.seq,
        };
    }
};

pub const Disposition = enum {
    /// Keep reading the stream.
    @"continue",
    /// The process exited; stop reading.
    stop,
};

pub const Applied = struct {
    disposition: Disposition,
    /// Query responses to write back (`WriteTerminal`), borrowed from the
    /// emulator until the next feed.
    responses: []const u8 = &.{},
    /// The frame was a replay (seq <= last applied) and was skipped.
    duplicate: bool = false,
};

pub const DataStream = struct {
    /// Highest applied seq; pass as `afterSeq` when (re)subscribing.
    last_seq: u64 = 0,
    have_seq: bool = false,
    exited: ?i32 = null,
    /// Frames dropped because their payload was not valid base64.
    undecodable: usize = 0,
    /// Seq gaps observed (frames the engine never delivered).
    gaps: usize = 0,
    scratch: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *DataStream, gpa: Allocator) void {
        self.scratch.deinit(gpa);
    }

    /// `afterSeq` for a resubscribe: null before the first frame.
    pub fn afterSeq(self: *const DataStream) ?u64 {
        return if (self.have_seq) self.last_seq else null;
    }

    pub fn apply(self: *DataStream, gpa: Allocator, emu: *Emulator, ev: Event) !Applied {
        const s = ev.seq();
        if (self.have_seq and s <= self.last_seq) return .{
            .disposition = if (self.exited != null) .stop else .@"continue",
            .duplicate = true,
        };
        if (self.have_seq and s > self.last_seq + 1) self.gaps += 1;
        self.last_seq = s;
        self.have_seq = true;
        switch (ev) {
            .data => |d| {
                const bytes = decodeBase64(gpa, &self.scratch, d.data) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        self.undecodable += 1;
                        return .{ .disposition = .@"continue" };
                    },
                };
                return .{ .disposition = .@"continue", .responses = emu.feed(bytes) };
            },
            .exit => |e| {
                self.exited = e.exit_code;
                var buf: [64]u8 = undefined;
                _ = emu.feed(exitMessage(&buf, e.exit_code));
                return .{ .disposition = .stop };
            },
        }
    }
};

/// Decode standard base64, falling back to unpadded (zeron's
/// `decode_base64`). Result borrows `scratch`.
pub fn decodeBase64(gpa: Allocator, scratch: *std.ArrayList(u8), data: []const u8) ![]const u8 {
    const std_dec = std.base64.standard.Decoder;
    if (std_dec.calcSizeForSlice(data)) |n| {
        try scratch.resize(gpa, n);
        if (std_dec.decode(scratch.items, data)) |_| return scratch.items else |_| {}
    } else |_| {}
    const nopad = std.base64.standard_no_pad.Decoder;
    const n = try nopad.calcSizeForSlice(data);
    try scratch.resize(gpa, n);
    try nopad.decode(scratch.items, data);
    return scratch.items;
}

/// Encode bytes for `WriteTerminal.data`. Caller owns.
pub fn encodeBase64(gpa: Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

/// The `[process exited N]` trailer, dimmed.
pub fn exitMessage(buf: []u8, code: i32) []const u8 {
    return std.fmt.bufPrint(buf, "\r\n\x1b[90m[process exited {d}]\x1b[0m\r\n", .{code}) catch unreachable;
}

/// Tab title from the session's shell path ("/bin/zsh" -> "zsh").
pub fn shellTitle(shell: []const u8) []const u8 {
    var name = shell;
    if (std.mem.lastIndexOfAny(u8, shell, "/\\")) |i| name = shell[i + 1 ..];
    name = std.mem.trim(u8, name, " \t\r\n");
    return if (name.len == 0) "terminal" else name;
}

/// Buffers keyboard bytes between flushes. `push` returns true exactly
/// when a flush timer should be scheduled (the buffer was empty), so at
/// most one timer is in flight per burst.
pub const InputCoalescer = struct {
    pending: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *InputCoalescer, gpa: Allocator) void {
        self.pending.deinit(gpa);
    }

    pub fn push(self: *InputCoalescer, gpa: Allocator, bytes: []const u8) !bool {
        const was_empty = self.pending.items.len == 0;
        try self.pending.appendSlice(gpa, bytes);
        return was_empty and self.pending.items.len > 0;
    }

    /// Take the buffered bytes (caller owns).
    pub fn take(self: *InputCoalescer, gpa: Allocator) ![]u8 {
        return self.pending.toOwnedSlice(gpa);
    }

    pub fn isEmpty(self: *const InputCoalescer) bool {
        return self.pending.items.len == 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "exit message and shell title" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\r\n\x1b[90m[process exited 3]\x1b[0m\r\n", exitMessage(&buf, 3));
    try testing.expectEqualStrings("zsh", shellTitle("/bin/zsh"));
    try testing.expectEqualStrings("pwsh.exe", shellTitle("C:\\Program Files\\pwsh.exe"));
    try testing.expectEqualStrings("terminal", shellTitle("/usr/bin/"));
    try testing.expectEqualStrings("bash", shellTitle("bash"));
}

test "coalescer schedules once per burst" {
    var c: InputCoalescer = .{};
    defer c.deinit(testing.allocator);
    try testing.expect(try c.push(testing.allocator, "a"));
    try testing.expect(!try c.push(testing.allocator, "b"));
    const got = try c.take(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ab", got);
    try testing.expect(c.isEmpty());
    try testing.expect(try c.push(testing.allocator, "c"));
    try testing.expect(!try c.push(testing.allocator, ""));
}

test "base64 decode with and without padding" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    try testing.expectEqualStrings("hi!", try decodeBase64(testing.allocator, &scratch, "aGkh"));
    try testing.expectEqualStrings("hi", try decodeBase64(testing.allocator, &scratch, "aGk="));
    try testing.expectEqualStrings("hi", try decodeBase64(testing.allocator, &scratch, "aGk"));
    try testing.expectError(error.InvalidCharacter, decodeBase64(testing.allocator, &scratch, "*&^"));
    const e = try encodeBase64(testing.allocator, "hi");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("aGk=", e);
}

test "data stream applies frames in seq order and drops replays" {
    const emu = try Emulator.create(testing.allocator, .{ .cols = 20, .rows = 4, .io = testing.io });
    defer emu.destroy();
    var ds: DataStream = .{};
    defer ds.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, null), ds.afterSeq());

    // "hello" then " world"
    _ = try ds.apply(testing.allocator, emu, .{ .data = .{ .seq = 1, .data = "aGVsbG8=" } });
    _ = try ds.apply(testing.allocator, emu, .{ .data = .{ .seq = 2, .data = "IHdvcmxk" } });
    // A replay of seq 2 (resubscribe overlap) must not print twice.
    const dup = try ds.apply(testing.allocator, emu, .{ .data = .{ .seq = 2, .data = "IHdvcmxk" } });
    try testing.expect(dup.duplicate);
    try testing.expectEqual(@as(?u64, 2), ds.afterSeq());

    const row = try emu.rowText(testing.allocator, 0);
    defer testing.allocator.free(row);
    try testing.expectEqualStrings("hello world", row);

    // Undecodable frames are dropped, not fatal.
    _ = try ds.apply(testing.allocator, emu, .{ .data = .{ .seq = 3, .data = "!!!" } });
    try testing.expectEqual(@as(usize, 1), ds.undecodable);

    // DSR query responses come back for WriteTerminal: ESC[6n
    const r = try ds.apply(testing.allocator, emu, .{ .data = .{ .seq = 5, .data = "G1s2bg==" } });
    try testing.expectEqualStrings("\x1b[1;12R", r.responses);
    try testing.expectEqual(@as(usize, 1), ds.gaps);

    const ex = try ds.apply(testing.allocator, emu, .{ .exit = .{ .seq = 6, .exit_code = 0 } });
    try testing.expectEqual(Disposition.stop, ex.disposition);
    try testing.expectEqual(@as(?i32, 0), ds.exited);
    const trailer = try emu.rowText(testing.allocator, 1);
    defer testing.allocator.free(trailer);
    try testing.expectEqualStrings("[process exited 0]", trailer);
}

test "event adapts the engine protocol union" {
    const Proto = union(enum) {
        data: struct { seq: u64, data: []const u8 },
        exit: struct { seq: u64, exitCode: i32, signal: ?[]const u8 = null },
    };
    const e = Event.fromProtocol(Proto{ .exit = .{ .seq = 9, .exitCode = 130 } });
    try testing.expectEqual(@as(u64, 9), e.seq());
    try testing.expectEqual(@as(i32, 130), e.exit.exit_code);
}
