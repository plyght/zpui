//! The transcript row model — port of zeron transcript.rs `rows_for_entry`,
//! `ToolItem`/`ToolDetail`, `tool_detail`, `call_block`, `top_gap_for`,
//! `diff_rows`, `tool_group_summary` and the parse wiring (`parse_for_row`).
//!
//! One row per BLOCK: a user message is one bubble row; assistant messages
//! split into one row per top-level markdown block plus consecutive-tool
//! groups (agent/spawn chips split out) and input/error/fork rows. Row ids are
//! stable (`{msg}#{part}.{block}` / `{msg}#g{n}`), versions are content
//! hashes, so a streaming commit only re-splices the rows whose bytes changed.
//!
//! Rows of one entry live in that entry's arena (`EntryRows`), rebuilt only
//! when the entry's fingerprint changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("zeron_engine");
const model = @import("zeron_model");
const mdm = @import("zeron_markdown");
const diff = @import("zeron_diff");
const assets = @import("zeron_assets");
const thought = @import("thought.zig");
const wl = @import("workspace_links.zig");
pub const badges = @import("badges.zig");

const protocol = engine.protocol;
const SessionMessageEntry = protocol.SessionMessageEntry;
const MessagePart = protocol.MessagePart;
const ToolCall = protocol.ToolCall;
const BlockTree = mdm.BlockTree;
const view = model.view;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const output_detail_max_lines: usize = 24;
pub const diff_detail_max_lines: usize = 600;
pub const call_wrap_cols: usize = 80;
pub const output_line_height: f32 = 18.0;
pub const output_body_pad: f32 = 12.0;
pub const detail_separator: f32 = 1.0;

pub const space_sm: f32 = 8;
pub const space_md: f32 = 12;
pub const space_lg: f32 = 16;
pub const md_block_gap: f32 = 12;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const ToolItemKind = enum(u8) { call, thought, note };

pub const OutputLines = struct {
    lines: []const []const u8,
    truncated_by: usize,
};

pub const ThoughtLines = struct {
    lines: []const thought.Line,
    truncated_by: usize,
};

pub const DiffDetail = struct {
    file: diff.FileDiff,
    old_text: ?[]const u8,
    new_text: []const u8,
};

pub const ToolDetail = union(enum) {
    output: OutputLines,
    thought: ThoughtLines,
    diff: DiffDetail,
    stats: []const protocol.ToolDiffStat,
};

/// One tool invocation (or synthesized thought/note) inside a group row —
/// precomputed display data, so rendering never re-derives it per frame.
pub const ToolItem = struct {
    part_id: []const u8,
    kind: ToolItemKind = .call,
    label: []const u8,
    detail: []const u8,
    icon: assets.Icon,
    /// File-action chips show a file badge (read/write/edit/patch).
    file_path: ?[]const u8 = null,
    is_agent: bool = false,
    subagent_model: ?[]const u8 = null,
    is_error: bool = false,
    resolved: bool = false,
    body: ?ToolDetail = null,
    invocation: ?ToolDetail = null,
    output_ref: ?[]const u8 = null,
    output_bytes: ?u64 = null,
    diff_ref: ?[]const u8 = null,
    subagent_ref: ?[]const u8 = null,
    subagent_status: ?protocol.SubagentStatus = null,

    pub fn isSpawnLink(self: ToolItem) bool {
        return self.is_agent and self.subagent_ref != null;
    }
};

pub const Attachment = struct {
    path: []const u8,
    name: []const u8,
};

pub const RowKind = union(enum) {
    user: struct {
        text: []const u8,
        attachments: []const Attachment,
        /// Context the prompt folded in as text, lifted back out (`badges`).
        badges: []const badges.MessageBadge = &.{},
        pending: bool,
    },
    markdown: struct {
        tree: *const BlockTree,
        block_ix: usize,
        live: bool,
    },
    tool_group: struct {
        summary: []const u8,
        tools: []const ToolItem,
        auto_open: bool,
        collapses: bool,
        /// Compact-mode settled duration for this turn, in seconds.
        worked_secs: ?i64 = null,
        /// Compact-mode work header: its expanded content is the sibling rows
        /// tagged `Row.compact_fold`, not chips.
        compact_shell: bool = false,
    },
    input_chip: struct { header: []const u8, resolved: bool },
    error_chip: struct { message: []const u8 },
    fork_marker: struct { source_title: []const u8 },
    generated_image: struct { owner: []const u8, path: []const u8, name: []const u8, mime_type: []const u8 },
};

pub const Row = struct {
    id: []const u8,
    version: u64,
    /// First row of its message entry (gets the turn gap).
    turn_start: bool = false,
    kind: RowKind,
    entry_id: []const u8,
    /// Hover-timestamp strip under this row (last settled row of an entry).
    timestamp: ?i64 = null,
    copy_text: ?[]const u8 = null,
    /// Hidden while the named compact-work fold (`{entry}#work`) is closed.
    compact_fold: ?[]const u8 = null,
    is_user: bool = false,
    /// Stable hash of `id` (element ids, selection keys).
    key: u64 = 0,
};

/// The rows of one entry plus everything they borrow.
pub const EntryRows = struct {
    arena: std.heap.ArenaAllocator,
    fingerprint: u64,
    rows: []Row = &.{},
    trees: std.ArrayList(*BlockTree) = .empty,
    patches: std.ArrayList(diff.PatchSet) = .empty,

    pub fn deinit(self: *EntryRows, gpa: Allocator) void {
        for (self.trees.items) |t| {
            t.deinit(gpa);
            gpa.destroy(t);
        }
        self.trees.deinit(gpa);
        for (self.patches.items) |*p| p.deinit();
        self.patches.deinit(gpa);
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Hashing / fingerprints
// ---------------------------------------------------------------------------

pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x1_0000_01b3;
    }
    return h;
}

pub fn hashStr(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7a3, s);
}

fn hashU64(h: *std.hash.Wyhash, v: u64) void {
    h.update(std.mem.asBytes(&v));
}

fn hashOpt(h: *std.hash.Wyhash, s: ?[]const u8) void {
    if (s) |x| {
        hashU64(h, x.len);
        h.update(x);
    } else hashU64(h, std.math.maxInt(u64));
}

fn hashJson(h: *std.hash.Wyhash, v: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(v, .{ .emit_null_optional_fields = false }, &w) catch {};
    h.update(w.buffered());
}

/// Content fingerprint of an entry (rebuild its rows only when it changes).
pub fn entryFingerprint(entry: *const SessionMessageEntry, pending: bool, compact: bool) u64 {
    var h = std.hash.Wyhash.init(0xe1);
    h.update(entry.id);
    h.update(&.{ @intFromEnum(entry.role), if (entry.status) |s| @intFromEnum(s) + 1 else 0, @intFromBool(pending), @intFromBool(compact) });
    hashU64(&h, @bitCast(entry.createdAt));
    hashU64(&h, @bitCast(entry.durationMs orelse -1));
    for (entry.parts) |part| {
        h.update(&.{@intFromEnum(std.meta.activeTag(part))});
        h.update(part.id());
        switch (part) {
            .text => |t| h.update(t.text),
            .reasoning => |t| h.update(t.text),
            .tool => |t| {
                h.update(&.{ @intFromBool(t.isError), @intFromBool(t.resolved) });
                hashOpt(&h, t.output);
                if (t.diff) |d| {
                    h.update(d.path);
                    hashOpt(&h, d.oldText);
                    h.update(d.newText);
                }
                hashOpt(&h, t.outputRef);
                hashOpt(&h, t.diffRef);
                hashOpt(&h, t.subagentRef);
                h.update(&.{if (t.subagentStatus) |s| @intFromEnum(s) + 1 else 0});
                if (t.diffStats) |stats| for (stats) |s| {
                    h.update(s.path);
                    hashU64(&h, s.additions);
                    hashU64(&h, s.deletions);
                };
                hashJson(&h, t.call);
            },
            .image => |im| {
                h.update(im.path);
                h.update(im.name);
            },
            .input => |in| {
                h.update(&.{@intFromBool(in.resolved)});
                if (in.questions.len > 0) h.update(in.questions[0].header);
            },
            .@"error" => |e| h.update(e.message),
            .fork => |f| h.update(f.sourceTitle),
        }
    }
    return h.final();
}

// ---------------------------------------------------------------------------
// Parse wiring (`parse_for_row`)
// ---------------------------------------------------------------------------

/// Live parts keep one `IncrementalParser` per `{entry}#{part}` key (O(tail)
/// reparse, display tree with hanging markers mended); completed parts hit a
/// settled cache, adopt the live parser's canonical tree on the live→complete
/// flip (flicker-free handoff), or parse once.
pub const Parsers = struct {
    gpa: Allocator,
    live: std.StringHashMapUnmanaged(*mdm.IncrementalParser) = .empty,
    settled: std.StringHashMapUnmanaged(Settled) = .empty,
    /// Keys touched since the last `sweep`.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Parse statistics (tests / diagnostics).
    full_parses: usize = 0,
    incremental: usize = 0,

    const Settled = struct { len: usize, hash: u64, tree: BlockTree };

    pub fn init(gpa: Allocator) Parsers {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Parsers) void {
        var it = self.live.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.live.deinit(self.gpa);
        var it2 = self.settled.iterator();
        while (it2.next()) |e| {
            e.value_ptr.tree.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.settled.deinit(self.gpa);
        self.seen.deinit(self.gpa);
    }

    /// The tree for one part (caller owns the returned handle).
    pub fn parse(self: *Parsers, key: []const u8, text: []const u8, streaming: bool) Allocator.Error!BlockTree {
        const gpa = self.gpa;
        if (streaming) {
            const gop = try self.live.getOrPut(gpa, key);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, key);
                const p = try gpa.create(mdm.IncrementalParser);
                p.* = .init(gpa);
                gop.value_ptr.* = p;
            }
            try gop.value_ptr.*.setText(text);
            self.incremental += 1;
            return gop.value_ptr.*.displayTree();
        }
        const h = std.hash.Wyhash.hash(0, text);
        if (self.settled.get(key)) |s| if (s.len == text.len and s.hash == h) return s.tree.clone(gpa);
        var tree: BlockTree = undefined;
        if (self.live.fetchRemove(key)) |kv| {
            defer {
                kv.value.deinit();
                gpa.destroy(kv.value);
                gpa.free(kv.key);
            }
            if (std.mem.eql(u8, kv.value.sourceText(), text)) {
                tree = try kv.value.canonical().clone(gpa);
            } else {
                tree = try mdm.parseFull(gpa, text);
                self.full_parses += 1;
            }
        } else {
            tree = try mdm.parseFull(gpa, text);
            self.full_parses += 1;
        }
        const gop = try self.settled.getOrPut(gpa, key);
        if (gop.found_existing) gop.value_ptr.tree.deinit(gpa) else gop.key_ptr.* = try gpa.dupe(u8, key);
        gop.value_ptr.* = .{ .len = text.len, .hash = h, .tree = tree };
        return tree.clone(gpa);
    }
};

// ---------------------------------------------------------------------------
// Tool details
// ---------------------------------------------------------------------------

fn trimTrailingBlank(lines: *std.ArrayList([]const u8)) void {
    while (lines.items.len > 0 and std.mem.trim(u8, lines.items[lines.items.len - 1], " \t\r").len == 0) _ = lines.pop();
}

fn splitLines(a: Allocator, text: []const u8) Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    // `str::lines` drops a final empty line after a trailing newline.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and std.mem.endsWith(u8, text, "\n")) _ = out.pop();
    return out;
}

/// Output → capped verbatim lines (`tool_detail` output branch).
pub fn outputDetail(a: Allocator, output: []const u8, cap: usize) Allocator.Error!?ToolDetail {
    var lines = try splitLines(a, try a.dupe(u8, output));
    trimTrailingBlank(&lines);
    if (lines.items.len == 0) return null;
    const truncated = lines.items.len -| cap;
    return .{ .output = .{ .lines = lines.items[0..@min(lines.items.len, cap)], .truncated_by = truncated } };
}

/// A tool part's expandable detail: diff wins, then diff stats, then output.
pub fn toolDetail(gpa: Allocator, a: Allocator, rows: *EntryRows, t: MessagePart.Tool) Allocator.Error!?ToolDetail {
    if (t.diff) |d| {
        var set = try diff.diffToFile(gpa, d.path, d.oldText, d.newText);
        if (set.files.len == 0 or set.files[0].hunks.len == 0) {
            set.deinit();
            return null;
        }
        try rows.patches.append(gpa, set);
        const ps = &rows.patches.items[rows.patches.items.len - 1];
        var file = ps.files[0];
        try diff.truncateFileLines(ps.arena.allocator(), &file, diff_detail_max_lines);
        return .{ .diff = .{
            .file = file,
            .old_text = if (d.oldText) |o| try a.dupe(u8, o) else null,
            .new_text = try a.dupe(u8, d.newText),
        } };
    }
    if (t.diffStats) |stats| if (stats.len > 0) {
        const out = try a.alloc(protocol.ToolDiffStat, stats.len);
        for (stats, out) |s, *o| o.* = .{ .path = try a.dupe(u8, s.path), .additions = s.additions, .deletions = s.deletions };
        return .{ .stats = out };
    };
    const output = t.output orelse return null;
    return outputDetail(a, output, output_detail_max_lines);
}

fn wrapColsInto(a: Allocator, out: *std.ArrayList([]const u8), line: []const u8, cols: usize) Allocator.Error!void {
    const n = std.unicode.utf8CountCodepoints(line) catch line.len;
    if (n <= cols) return out.append(a, line);
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (true) {
        const start = it.i;
        var k: usize = 0;
        while (k < cols) : (k += 1) if (it.nextCodepointSlice() == null) break;
        if (it.i == start) break;
        try out.append(a, line[start..it.i]);
    }
}

fn prettyJson(a: Allocator, v: std.json.Value) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// The full-invocation block (`call_block`).
pub fn callBlock(a: Allocator, call: ToolCall) Allocator.Error!?ToolDetail {
    const text: []const u8 = switch (call) {
        .exec => |c| c.command,
        .readFile => |c| c.path,
        .writeFile => |c| if (c.content) |content| try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.path, content }) else c.path,
        .editFile => |c| c.path,
        .applyPatch => |c| c.path orelse "workspace",
        .search => |c| if (c.path) |p| try std.fmt.allocPrint(a, "{s} in {s}", .{ c.pattern, p }) else c.pattern,
        .glob => |c| c.pattern,
        .webFetch => |c| if (c.prompt) |p| try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.url, p }) else c.url,
        .webSearch => |c| c.query,
        .todo => |c| blk: {
            var buf: std.ArrayList(u8) = .empty;
            for (c.items, 0..) |item, i| {
                if (i > 0) try buf.append(a, '\n');
                const mark = switch (item.effectiveStatus()) {
                    .completed => "[x]",
                    .inProgress => "[~]",
                    .pending => "[ ]",
                };
                try buf.print(a, "{s} {s}", .{ mark, item.text });
            }
            break :blk buf.items;
        },
        .mcp => |c| if (c.input) |in| try std.fmt.allocPrint(a, "{s} · {s}\n{s}", .{ c.server, c.tool, try prettyJson(a, in) }) else try std.fmt.allocPrint(a, "{s} · {s}", .{ c.server, c.tool }),
        .unknown => |c| if (c.input) |in| try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.name, try prettyJson(a, in) }) else c.name,
    };
    const owned = try a.dupe(u8, text);
    var raw = try splitLines(a, owned);
    var lines: std.ArrayList([]const u8) = .empty;
    for (raw.items) |l| try wrapColsInto(a, &lines, l, call_wrap_cols);
    raw.deinit(a);
    trimTrailingBlank(&lines);
    if (lines.items.len == 0) return null;
    const truncated = lines.items.len -| output_detail_max_lines;
    return .{ .output = .{ .lines = lines.items[0..@min(lines.items.len, output_detail_max_lines)], .truncated_by = truncated } };
}

/// The glyph for a tool call (zeron tool-chip.tsx `toolIcon`, Solar set).
pub fn toolIcon(call: ToolCall) assets.Icon {
    return switch (call) {
        .exec => .terminal,
        .readFile, .applyPatch => .document,
        .writeFile => .document_add,
        .editFile => .pen,
        .search => .magnifer,
        .glob => .folder_with_files,
        .webFetch, .webSearch => .global,
        .todo => .checklist,
        .mcp, .unknown => if (call.isSubagentSpawn()) .bot else switch (call) {
            .unknown => |u| if (std.mem.eql(u8, u.name, "Wait for agents")) .bot else .widget,
            else => .widget,
        },
    };
}

fn subagentModel(call: ToolCall) ?[]const u8 {
    if (!call.isSubagentSpawn()) return null;
    const input = switch (call) {
        .unknown => |u| u.input,
        .mcp => |m| m.input,
        else => null,
    } orelse return null;
    if (input != .object) return null;
    for ([_][]const u8{ "model", "modelId", "model_id", "subagent_model" }) |k| {
        if (input.object.get(k)) |v| if (v == .string) {
            const m = std.mem.trim(u8, v.string, " \t\r\n");
            if (m.len > 0) return m;
        };
    }
    return null;
}

fn toolItem(gpa: Allocator, a: Allocator, rows: *EntryRows, part: MessagePart.Tool) Allocator.Error!ToolItem {
    const chip = try view.toolChipContent(a, part.call);
    const path: ?[]const u8 = switch (part.call) {
        .readFile => |c| c.path,
        .writeFile => |c| c.path,
        .editFile => |c| c.path,
        .applyPatch => |c| c.path,
        else => null,
    };
    return .{
        .part_id = try a.dupe(u8, part.id),
        .label = chip.label,
        .detail = chip.detail,
        .icon = toolIcon(part.call),
        .file_path = if (path) |p| try a.dupe(u8, p) else null,
        .is_agent = part.call.isSubagentSpawn(),
        .subagent_model = if (subagentModel(part.call)) |m| try a.dupe(u8, m) else null,
        .is_error = part.isError,
        .resolved = part.resolved,
        .body = try toolDetail(gpa, a, rows, part),
        .invocation = try callBlock(a, part.call),
        .output_ref = if (part.outputRef) |r| try a.dupe(u8, r) else null,
        .output_bytes = part.outputBytes,
        .diff_ref = if (part.diffRef) |r| try a.dupe(u8, r) else null,
        .subagent_ref = if (part.subagentRef) |r| try a.dupe(u8, r) else null,
        .subagent_status = part.subagentStatus,
    };
}

fn thoughtItem(a: Allocator, part_id: []const u8, tree: BlockTree, live: bool, kind: ToolItemKind) Allocator.Error!ToolItem {
    var lines: std.ArrayList(thought.Line) = .fromOwnedSlice(try thought.thoughtLines(a, tree));
    var truncated = lines.items.len -| output_detail_max_lines;
    if (truncated > 0) {
        if (live) {
            // Keep the TAIL while streaming (the fresh thinking is the signal).
            const tail = lines.items[truncated..];
            var start: usize = 0;
            while (start < tail.len and thought.isBlank(tail[start])) start += 1;
            lines = .fromOwnedSlice(tail[start..]);
        } else lines.shrinkRetainingCapacity(output_detail_max_lines);
    } else truncated = 0;
    var detail_line: []const u8 = "";
    if (kind == .note) {
        // First non-blank flattened line, collapsed onto one line.
        for (lines.items) |line| {
            var buf: std.ArrayList(u8) = .empty;
            for (line) |r| try buf.appendSlice(a, r.text);
            const one = try view.singleLine(a, buf.items);
            if (one.len > 0) {
                detail_line = one;
                break;
            }
        }
    }
    return .{
        .part_id = try a.dupe(u8, part_id),
        .kind = kind,
        .label = if (kind == .note) "Wrote" else "Thought process",
        .detail = detail_line,
        .icon = if (kind == .note) .pen else .chat_round_line,
        .resolved = !live,
        .body = if (lines.items.len > 0) .{ .thought = .{ .lines = lines.items, .truncated_by = truncated } } else null,
    };
}

/// The ToolGroup summary line, including thought/note segments.
pub fn toolGroupSummary(a: Allocator, calls: []const view.ToolEntry, thoughts: usize, notes: usize) Allocator.Error![]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    switch (thoughts) {
        0 => {},
        1 => try segs.append(a, "thought process"),
        else => try segs.append(a, try std.fmt.allocPrint(a, "thought {d} times", .{thoughts})),
    }
    switch (notes) {
        0 => {},
        1 => try segs.append(a, "wrote a note"),
        else => try segs.append(a, try std.fmt.allocPrint(a, "wrote {d} notes", .{notes})),
    }
    if (calls.len > 0) try segs.append(a, try view.toolGroupSummary(a, calls));
    const out = try std.mem.join(a, " · ", segs.items);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ---------------------------------------------------------------------------
// User messages
// ---------------------------------------------------------------------------

/// `agent_message_display`: a concise attribution for agent-routed prompts.
pub fn agentMessageDisplay(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const prefix = "[Message from Zeron chat ";
    if (!std.mem.startsWith(u8, text, prefix)) return text;
    const rest = text[prefix.len..];
    const sep = std.mem.indexOf(u8, rest, "]\n\n") orelse return text;
    const header = rest[0..sep];
    const body = rest[sep + 3 ..];
    const mid = ". Reply to it with the Zeron `send_message` tool, chat ";
    const at = std.mem.lastIndexOf(u8, header, mid) orelse return text;
    const label = header[0..at];
    const id_dot = header[at + mid.len ..];
    if (!std.mem.endsWith(u8, id_dot, ".")) return text;
    const id = id_dot[0 .. id_dot.len - 1];
    const suffix = try std.fmt.allocPrint(a, " ({s})", .{id});
    const name = if (std.mem.endsWith(u8, label, suffix)) label[0 .. label.len - suffix.len] else label;
    return std.fmt.allocPrint(a, "Message from {s}\n\n{s}", .{ name, body });
}

pub const ParsedUser = struct { text: []const u8, attachments: []const Attachment };

/// `parse_user_message_images`: split the visible prompt from its
/// attachment-ref trailer ("\n\nAttached images (local files …):\n- path").
pub fn parseUserMessageImages(a: Allocator, content: []const u8) Allocator.Error!ParsedUser {
    const lower = try std.ascii.allocLowerString(a, content);
    const needle = "\n\nattached images (local files";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, lower, from, needle)) |gap| {
        const line_start = gap + 2;
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = std.mem.trimEnd(u8, content[line_start..line_end], "\r");
        if (std.mem.endsWith(u8, line, "):")) {
            const refs_start = @min(line_end + 1, content.len);
            var atts: std.ArrayList(Attachment) = .empty;
            var it = std.mem.splitScalar(u8, content[refs_start..], '\n');
            while (it.next()) |l| {
                const t = std.mem.trimStart(u8, l, " \t");
                if (!std.mem.startsWith(u8, t, "- ")) continue;
                const path = std.mem.trim(u8, t[2..], " \t\r");
                if (path.len == 0) continue;
                var name = path;
                if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| name = path[i + 1 ..];
                if (name.len == 0) name = "image";
                try atts.append(a, .{ .path = path, .name = name });
            }
            if (atts.items.len == 0) return .{ .text = content, .attachments = &.{} };
            const body = std.mem.trimEnd(u8, content[0..gap], " \t\r\n");
            return .{
                .text = if (std.mem.eql(u8, std.mem.trim(u8, body, " \t\r\n"), "See the attached image(s).")) "" else body,
                .attachments = atts.items,
            };
        }
        from = line_start;
    }
    return .{ .text = content, .attachments = &.{} };
}

// ---------------------------------------------------------------------------
// rows_for_entry
// ---------------------------------------------------------------------------

pub const BuildOptions = struct {
    pending: bool = false,
    /// Inline-code file-link probing (workspace roots); null = off.
    probe: ?*wl.Probe = null,
    /// The transcript's compact mode (`transcriptCompactMode`): every working
    /// step of a turn folds into ONE collapsed work group, so only the reply
    /// (the trailing run of text parts) stays visible rows.
    compact: bool = false,
};

fn isAgentTool(item: ToolItem) bool {
    return item.is_agent;
}

const Group = struct {
    items: std.ArrayList(ToolItem) = .empty,
    calls: std.ArrayList(view.ToolEntry) = .empty,
    thoughts: usize = 0,
    notes: usize = 0,
    last_part_ix: usize = 0,
};

fn toolFingerprint(tools: []const ToolItem, auto_open: bool) u64 {
    var h = std.hash.Wyhash.init(0x7001);
    for (tools) |t| {
        h.update(t.part_id);
        h.update(t.label);
        h.update(t.detail);
        h.update(&.{ @intFromBool(t.is_error), @intFromBool(t.resolved), @intFromEnum(t.kind), @intFromBool(t.output_ref != null), @intFromBool(t.diff_ref != null), if (t.subagent_status) |s| @intFromEnum(s) + 1 else 0 });
        if (t.body) |b| switch (b) {
            .output => |o| {
                hashU64(&h, o.lines.len);
                for (o.lines) |l| h.update(l);
            },
            .thought => |o| {
                hashU64(&h, o.lines.len);
                for (o.lines) |l| for (l) |r| {
                    h.update(r.text);
                    h.update(&.{ @intFromBool(r.style.bold), @intFromBool(r.style.italic), @intFromBool(r.style.code) });
                };
            },
            .diff => |d| {
                h.update(d.file.path);
                hashU64(&h, d.file.additions);
                hashU64(&h, d.file.deletions);
            },
            .stats => |s| hashU64(&h, s.len),
        };
        if (t.invocation) |inv| for (inv.output.lines) |l| h.update(l);
    }
    h.update(&.{@intFromBool(auto_open)});
    return h.final();
}

fn nonBlankText(part: MessagePart) bool {
    return switch (part) {
        .text => |t| std.mem.trim(u8, t.text, " \t\r\n").len > 0,
        else => false,
    };
}

/// Compact mode's reply boundary: where the turn's TRAILING run of non-empty
/// text parts begins. Null while the turn streams (no reply yet) or when it
/// ends on work.
pub fn compactReplyStart(entry: *const SessionMessageEntry) ?usize {
    if (entry.status == .streaming) return null;
    var i = entry.parts.len;
    var start: usize = while (i > 0) {
        i -= 1;
        if (nonBlankText(entry.parts[i])) break i;
    } else return null;
    while (start > 0 and nonBlankText(entry.parts[start - 1])) start -= 1;
    return start;
}

/// `is_compact_work_part`: the parts the compact work fold stands for.
pub fn isCompactWorkPart(ix: usize, part: MessagePart, reply_start: ?usize) bool {
    return switch (part) {
        .tool => true,
        .reasoning => |r| std.mem.trim(u8, r.text, " \t\r\n").len > 0,
        .text => |t| std.mem.trim(u8, t.text, " \t\r\n").len > 0 and (reply_start == null or ix < reply_start.?),
        else => false,
    };
}

/// The settled duration a compact work header shows ("Worked for 5m 10s"):
/// whole seconds, at least 1, only once the turn stopped streaming.
pub fn compactWorkedSecs(entry: *const SessionMessageEntry) ?i64 {
    if (entry.status == .streaming) return null;
    const ms = entry.durationMs orelse return null;
    if (ms <= 0) return null;
    return @max(@divTrunc(ms, 1000), 1);
}

/// Build the block rows of one entry into a fresh `EntryRows`.
pub fn buildEntryRows(gpa: Allocator, parsers: *Parsers, entry: *const SessionMessageEntry, opts: BuildOptions, fingerprint: u64) Allocator.Error!EntryRows {
    var er: EntryRows = .{ .arena = .init(gpa), .fingerprint = fingerprint };
    errdefer er.deinit(gpa);
    er.rows = try buildRows(gpa, parsers, &er, entry, opts, opts.compact);
    finalizeKeys(er.rows);
    return er;
}

/// `rows_for_entry`: the rows of `entry` (arena memory of `er`).
fn buildRows(gpa: Allocator, parsers: *Parsers, er: *EntryRows, entry: *const SessionMessageEntry, opts: BuildOptions, compact: bool) Allocator.Error![]Row {
    const a = er.arena.allocator();
    var rows: std.ArrayList(Row) = .empty;
    const streaming = entry.status == .streaming;
    const entry_id = try a.dupe(u8, entry.id);

    if (entry.role == .user) {
        var raw: std.ArrayList(u8) = .empty;
        var first = true;
        for (entry.parts) |p| switch (p) {
            .text => |t| {
                if (!first) try raw.appendSlice(a, "\n\n");
                first = false;
                try raw.appendSlice(a, t.text);
            },
            else => {},
        };
        const parsed = try parseUserMessageImages(a, raw.items);
        // Lifted before the attribution rewrite, so a comment body's own
        // Markdown never lands in the bubble (`badges::split`).
        const split = try badges.split(a, parsed.text);
        const text = try agentMessageDisplay(a, split.text);
        try rows.append(a, .{
            .id = entry_id,
            .version = (@as(u64, raw.items.len) << 1) | @intFromBool(opts.pending),
            .turn_start = true,
            .kind = .{ .user = .{ .text = text, .attachments = parsed.attachments, .badges = split.badges, .pending = opts.pending } },
            .entry_id = entry_id,
            .timestamp = entry.createdAt,
            .copy_text = if (std.mem.trim(u8, text, " \t\r\n").len > 0) text else null,
            .is_user = true,
        });
        return rows.items;
    }

    const last_part_ix = entry.parts.len -| 1;
    const reply_start: ?usize = if (compact) compactReplyStart(entry) else null;
    var group_ix: usize = 0;
    var group: Group = .{};
    // Compact mode: the row index the single work group lands at — the
    // position of the FIRST foldable part, so input/error chips ahead of it
    // keep their doc order.
    var compact_group_pos: ?usize = null;

    for (entry.parts, 0..) |part, part_ix| {
        switch (part) {
            .tool => |t| {
                const item = try toolItem(gpa, a, er, t);
                if (compact) {
                    // ONE group for the whole turn: agent chips fold in too.
                    if (compact_group_pos == null) compact_group_pos = rows.items.len;
                } else if (group.items.items.len > 0 and isAgentTool(group.items.items[0]) != item.is_agent)
                    try flushGroup(a, &rows, &group, &group_ix, entry_id, streaming, last_part_ix);
                try group.items.append(a, item);
                try group.calls.append(a, .{ .call = t.call, .is_error = t.isError });
                group.last_part_ix = part_ix;
            },
            .reasoning => |r| {
                if (std.mem.trim(u8, r.text, " \t\r\n").len == 0) continue;
                const live = streaming and part_ix == last_part_ix;
                const key = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, r.id });
                var tree = try parsers.parse(key, r.text, live);
                defer tree.deinit(gpa);
                const item = try thoughtItem(a, r.id, tree, live, .thought);
                if (compact) {
                    if (compact_group_pos == null) compact_group_pos = rows.items.len;
                } else if (group.items.items.len > 0 and isAgentTool(group.items.items[0]))
                    try flushGroup(a, &rows, &group, &group_ix, entry_id, streaming, last_part_ix);
                try group.items.append(a, item);
                group.thoughts += 1;
                group.last_part_ix = part_ix;
            },
            else => {
                // Compact mode: narration text folds into the work group as a
                // "Wrote" chip — only the reply stays a row.
                if (compact and nonBlankText(part) and (reply_start == null or part_ix < reply_start.?)) {
                    if (compact_group_pos == null) compact_group_pos = rows.items.len;
                    const t = part.text;
                    const key = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, t.id });
                    var tree = try parsers.parse(key, t.text, streaming);
                    defer tree.deinit(gpa);
                    const live = streaming and part_ix == last_part_ix;
                    try group.items.append(a, try thoughtItem(a, t.id, tree, live, .note));
                    group.notes += 1;
                    group.last_part_ix = part_ix;
                    continue;
                }
                if (!compact) try flushGroup(a, &rows, &group, &group_ix, entry_id, streaming, last_part_ix);
                switch (part) {
                    .text => |t| {
                        if (std.mem.trim(u8, t.text, " \t\r\n").len == 0) continue;
                        const key = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, t.id });
                        const tree = try gpa.create(BlockTree);
                        tree.* = parsers.parse(key, t.text, streaming) catch |e| {
                            gpa.destroy(tree);
                            return e;
                        };
                        if (opts.probe) |probe| {
                            probe.arena = a;
                            if (mdm.inline_code_links.linkTree(gpa, tree.*, wl.resolver(probe))) |linked| {
                                tree.deinit(gpa);
                                tree.* = linked;
                            } else |_| {}
                        }
                        try er.trees.append(gpa, tree);
                        for (tree.blocks, 0..) |top, block_ix| {
                            const end = @min(top.range.end, t.text.len);
                            const bytes = t.text[@min(top.range.start, end)..end];
                            try rows.append(a, .{
                                .id = try std.fmt.allocPrint(a, "{s}.{d}", .{ key, block_ix }),
                                .version = (fnv1a(bytes) << 1) | @intFromBool(streaming),
                                .kind = .{ .markdown = .{ .tree = tree, .block_ix = block_ix, .live = streaming } },
                                .entry_id = entry_id,
                            });
                        }
                    },
                    .image => |im| try rows.append(a, .{
                        .id = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, im.id }),
                        .version = fnv1a(im.path) ^ fnv1a(im.name),
                        .kind = .{ .generated_image = .{ .owner = try a.dupe(u8, entry.deviceId), .path = try a.dupe(u8, im.path), .name = try a.dupe(u8, im.name), .mime_type = try a.dupe(u8, im.mimeType) } },
                        .entry_id = entry_id,
                    }),
                    .input => |in| {
                        const header = try view.singleLine(a, if (in.questions.len > 0) in.questions[0].header else "Question");
                        try rows.append(a, .{
                            .id = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, in.id }),
                            .version = (fnv1a(header) << 1) | @intFromBool(in.resolved),
                            .kind = .{ .input_chip = .{ .header = header, .resolved = in.resolved } },
                            .entry_id = entry_id,
                        });
                    },
                    .@"error" => |e| try rows.append(a, .{
                        .id = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, e.id }),
                        .version = e.message.len,
                        .kind = .{ .error_chip = .{ .message = try view.singleLine(a, e.message) } },
                        .entry_id = entry_id,
                    }),
                    .fork => |f| try rows.append(a, .{
                        .id = try std.fmt.allocPrint(a, "{s}#{s}", .{ entry.id, f.id }),
                        .version = fnv1a(f.sourceTitle),
                        .kind = .{ .fork_marker = .{ .source_title = try view.singleLine(a, f.sourceTitle) } },
                        .entry_id = entry_id,
                    }),
                    .tool, .reasoning => unreachable,
                }
            },
        }
    }
    if (compact) {
        // Collapsed: one work header. Expanded: the same rows compact-off
        // would emit for the work parts, tagged so the fold can hide them.
        if (group.items.items.len > 0) {
            const tools = group.items.items;
            const work_id = try std.fmt.allocPrint(a, "{s}#work", .{entry.id});
            var work_parts: std.ArrayList(MessagePart) = .empty;
            for (entry.parts, 0..) |part, ix| if (isCompactWorkPart(ix, part, reply_start)) try work_parts.append(a, part);
            const inner: []Row = if (work_parts.items.len == 0) &.{} else blk: {
                var work_entry = entry.*;
                work_entry.parts = work_parts.items;
                work_entry.durationMs = null;
                work_entry.continuationOf = null;
                break :blk try buildRows(gpa, parsers, er, &work_entry, opts, false);
            };
            for (inner) |*row| {
                row.turn_start = false;
                row.timestamp = null;
                row.copy_text = null;
                row.compact_fold = work_id;
            }
            const header: Row = .{
                .id = work_id,
                .version = toolFingerprint(tools, false),
                .kind = .{ .tool_group = .{
                    .summary = try toolGroupSummary(a, group.calls.items, group.thoughts, group.notes),
                    .tools = tools,
                    .auto_open = false,
                    .collapses = true,
                    .worked_secs = compactWorkedSecs(entry),
                    .compact_shell = true,
                } },
                .entry_id = entry_id,
            };
            const pos = compact_group_pos orelse rows.items.len;
            try rows.insertSlice(a, pos, inner);
            try rows.insert(a, pos, header);
        }
    } else try flushGroup(a, &rows, &group, &group_ix, entry_id, streaming, last_part_ix);

    if (rows.items.len > 0) rows.items[0].turn_start = true;
    if (!streaming and rows.items.len > 0) {
        const last = &rows.items[rows.items.len - 1];
        if (last.kind != .fork_marker) {
            last.timestamp = entry.createdAt;
            last.copy_text = try assistantCopyText(a, entry);
            last.version ^= @as(u64, 1) << 62;
        }
    }
    return rows.items;
}

fn finalizeKeys(rows: []Row) void {
    for (rows) |*r| r.key = hashStr(r.id);
}

fn flushGroup(a: Allocator, rows: *std.ArrayList(Row), group: *Group, group_ix: *usize, entry_id: []const u8, streaming: bool, last_part_ix: usize) Allocator.Error!void {
    if (group.items.items.len == 0) return;
    const tools = group.items.items;
    const auto_open = streaming and group.last_part_ix == last_part_ix;
    var collapses = false;
    for (tools) |t| if (!t.is_agent) {
        collapses = true;
    };
    try rows.append(a, .{
        .id = try std.fmt.allocPrint(a, "{s}#g{d}", .{ entry_id, group_ix.* }),
        .version = toolFingerprint(tools, auto_open),
        .kind = .{ .tool_group = .{
            .summary = try toolGroupSummary(a, group.calls.items, group.thoughts, group.notes),
            .tools = tools,
            .auto_open = auto_open,
            .collapses = collapses,
        } },
        .entry_id = entry_id,
    });
    group_ix.* += 1;
    group.* = .{};
}

fn assistantCopyText(a: Allocator, entry: *const SessionMessageEntry) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (entry.parts) |p| switch (p) {
        .text => |t| if (std.mem.trim(u8, t.text, " \t\r\n").len > 0) try parts.append(a, t.text),
        else => {},
    };
    if (parts.items.len == 0) return null;
    return try std.mem.join(a, "\n\n", parts.items);
}

// ---------------------------------------------------------------------------
// Gaps / diffing
// ---------------------------------------------------------------------------

fn partPrefix(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '.')) |i| id[0..i] else id;
}

/// Vertical gap opening `row` given its predecessor (`top_gap_for`).
pub fn topGapFor(prev: ?*const Row, row: *const Row) f32 {
    if (row.turn_start) return space_lg;
    const is_md = row.kind == .markdown;
    if (prev) |p| {
        if (is_md and p.kind == .markdown and std.mem.eql(u8, partPrefix(p.id), partPrefix(row.id))) return md_block_gap;
        if (p.kind == .tool_group) return space_md;
    }
    if (row.kind == .tool_group) return space_md;
    return space_sm;
}

pub const Splice = struct { start: usize, old_end: usize, new_count: usize };

/// Minimal splice between two row sets by (id, version); null if identical.
pub fn diffRows(old_ids: []const u64, old_versions: []const u64, new: []const Row) ?Splice {
    var prefix: usize = 0;
    const max_prefix = @min(old_ids.len, new.len);
    while (prefix < max_prefix and old_ids[prefix] == new[prefix].key and old_versions[prefix] == new[prefix].version) prefix += 1;
    if (prefix == old_ids.len and prefix == new.len) return null;
    var suffix: usize = 0;
    const max_suffix = @min(old_ids.len - prefix, new.len - prefix);
    while (suffix < max_suffix and old_ids[old_ids.len - 1 - suffix] == new[new.len - 1 - suffix].key and
        old_versions[old_versions.len - 1 - suffix] == new[new.len - 1 - suffix].version) suffix += 1;
    return .{ .start = prefix, .old_end = old_ids.len - suffix, .new_count = new.len - suffix - prefix };
}

// ---------------------------------------------------------------------------
// Pure helpers (formatting)
// ---------------------------------------------------------------------------

/// Compact elapsed formatting ("12s", "3m 4s", "2h 5m", "1d 3h").
pub fn formatElapsed(buf: []u8, secs_in: i64) []const u8 {
    const secs: u64 = @intCast(@max(secs_in, 0));
    return (if (secs < 60)
        std.fmt.bufPrint(buf, "{d}s", .{secs})
    else if (secs < 3600)
        std.fmt.bufPrint(buf, "{d}m {d}s", .{ secs / 60, secs % 60 })
    else if (secs < 86_400)
        std.fmt.bufPrint(buf, "{d}h {d}m", .{ secs / 3600, (secs % 3600) / 60 })
    else
        std.fmt.bufPrint(buf, "{d}d {d}h", .{ secs / 86_400, (secs % 86_400) / 3600 })) catch "";
}

pub const flavour_words = [_][]const u8{
    "Zeroning",   "Thinking",   "Pondering",  "Scheming",      "Brewing",     "Weaving",    "Tinkering",
    "Musing",     "Composing",  "Sifting",    "Untangling",    "Distilling",  "Sketching",  "Plotting",
    "Riffing",    "Combobulating", "Percolating", "Marinating", "Noodling",  "Puzzling",   "Conjuring",
};

pub fn flavourWord(seed: u64, elapsed_secs: i64) []const u8 {
    const step: u64 = @intCast(@divTrunc(@max(elapsed_secs, 0), 7));
    return flavour_words[@intCast((seed +% step) % flavour_words.len)];
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "Jul 1, 3:45 PM" (`format_timestamp`), at a UTC offset in minutes.
pub fn formatTimestamp(buf: []u8, ms: i64, offset_minutes: i32) []const u8 {
    const secs = @divFloor(ms, 1000) + @as(i64, offset_minutes) * 60;
    if (secs < 0) return "";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const h24 = ds.getHoursIntoDay();
    const h12 = if (h24 % 12 == 0) 12 else h24 % 12;
    return std.fmt.bufPrint(buf, "{s} {d}, {d}:{d:0>2} {s}", .{
        month_names[md.month.numeric() - 1], md.day_index + 1, h12, ds.getMinutesIntoHour(), if (h24 < 12) "AM" else "PM",
    }) catch "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "timestamp and elapsed formats" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Jul 1, 3:45 PM", formatTimestamp(&buf, 1782920700000, 0));
    try std.testing.expectEqualStrings("3m 4s", formatElapsed(&buf, 184));
    try std.testing.expectEqualStrings("1d 3h", formatElapsed(&buf, 97200));
}

test "user attachments split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseUserMessageImages(arena.allocator(), "look\n\nAttached images (local files, read them):\n- /tmp/a.png\n- /tmp/b.jpg");
    try std.testing.expectEqualStrings("look", p.text);
    try std.testing.expectEqual(@as(usize, 2), p.attachments.len);
    try std.testing.expectEqualStrings("b.jpg", p.attachments[1].name);
}

test "rows split per block and group tools" {
    const gpa = std.testing.allocator;
    var parsers = Parsers.init(gpa);
    defer parsers.deinit();
    var parts = [_]MessagePart{
        .{ .text = .{ .id = "p1", .text = "Hello\n\nWorld" } },
        .{ .tool = .{ .id = "t1", .call = .{ .exec = .{ .command = "ls" } }, .resolved = true, .output = "a\nb\n" } },
        .{ .tool = .{ .id = "t2", .call = .{ .readFile = .{ .path = "src/main.zig" } }, .resolved = true } },
        .{ .reasoning = .{ .id = "r1", .text = "thinking **hard**" } },
        .{ .text = .{ .id = "p2", .text = "Done" } },
    };
    const entry: SessionMessageEntry = .{ .id = "m1", .role = .assistant, .parts = &parts, .createdAt = 0, .deviceId = "d", .status = .complete };
    var er = try buildEntryRows(gpa, &parsers, &entry, .{}, 1);
    defer er.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), er.rows.len);
    try std.testing.expectEqualStrings("m1#p1.0", er.rows[0].id);
    try std.testing.expectEqualStrings("m1#g0", er.rows[2].id);
    try std.testing.expectEqualStrings("Thought process · Ran 1 command · read 1 file", er.rows[2].kind.tool_group.summary);
    try std.testing.expect(er.rows[0].turn_start);
    try std.testing.expect(er.rows[3].timestamp != null);
    try std.testing.expectEqual(md_block_gap, topGapFor(&er.rows[0], &er.rows[1]));
    try std.testing.expectEqual(space_md, topGapFor(&er.rows[1], &er.rows[2]));
}
