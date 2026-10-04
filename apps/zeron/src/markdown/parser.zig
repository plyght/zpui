//! Block-level markdown parsing — port of `zeron_markdown::parser`.
//!
//! Full parses build a [`BlockTree`] of top-level blocks with byte ranges in
//! the source. [`IncrementalParser`] reparses only from the last stable
//! top-level block boundary, so a streamed delta costs O(delta + last block).
//!
//! Soundness guard: link-reference definitions act at a distance, so a source
//! containing one drops to full reparses.
//!
//! Event source: `cmark/` is a faithful port of pulldown-cmark 0.12.2 (the
//! exact parser + options zeron links), so events and offsets match.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const cmark = @import("cmark/parse.zig");
const mend = @import("mend.zig");
const unicode = @import("cmark/unicode.zig");

pub const Range = model.Range;
pub const InlineStyle = model.InlineStyle;
pub const InlineRun = model.InlineRun;
pub const InlineImage = model.InlineImage;
pub const TaskMarker = model.TaskMarker;
pub const TableAlign = model.TableAlign;
pub const Block = model.Block;
pub const TopBlock = model.TopBlock;
pub const BlockTree = model.BlockTree;

const Event = cmark.Event;
const OffsetEvent = cmark.OffsetEvent;

// ---------------------------------------------------------------------------
// Full parse
// ---------------------------------------------------------------------------

/// Parse a whole source into a [`BlockTree`]. `gpa` backs the returned tree
/// (each top block keeps its own arena on it).
pub fn parseFull(gpa: Allocator, source: []const u8) Allocator.Error!BlockTree {
    var list: std.ArrayList(*TopBlock) = .empty;
    errdefer {
        for (list.items) |b| b.release();
        list.deinit(gpa);
    }
    try parseAt(gpa, source, 0, &list);
    return .{ .blocks = try list.toOwnedSlice(gpa) };
}

/// Byte positions, in the rewritten text, of inserted angle brackets.
const Insertions = struct {
    positions: std.ArrayList(usize) = .empty,

    fn original(self: *const Insertions, offset: usize) usize {
        // partition_point(|&at| at < offset)
        var lo: usize = 0;
        var hi: usize = self.positions.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.positions.items[mid] < offset) lo = mid + 1 else hi = mid;
        }
        return offset - lo;
    }
};

fn parseAt(gpa: Allocator, source: []const u8, offset: usize, out: *std.ArrayList(*TopBlock)) Allocator.Error!void {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    var insertions: Insertions = .{};
    const rewritten = try rewriteAbsoluteDestinations(tmp, source, &insertions);
    const text = rewritten orelse source;
    const events = try cmark.collectEvents(tmp, text);
    for (events) |*ev| {
        if (rewritten != null) {
            ev.start = insertions.original(ev.start);
            ev.end = insertions.original(ev.end);
        }
        ev.start += offset;
        ev.end += offset;
    }

    var cur: Cursor = .{ .events = events };
    while (cur.peek()) |oe| {
        const range: Range = .{ .start = oe.start, .end = oe.end };
        switch (oe.event) {
            .rule => {
                cur.bump();
                const tb = try TopBlock.create(gpa);
                tb.range = range;
                tb.block = .rule;
                try out.append(gpa, tb);
            },
            .start => {
                var arena = std.heap.ArenaAllocator.init(gpa);
                var b: Builder = .{ .a = arena.allocator() };
                var blocks: std.ArrayList(Block) = .empty;
                b.parseStartedBlock(&cur, &blocks) catch |e| {
                    arena.deinit();
                    return e;
                };
                if (blocks.items.len == 0) {
                    arena.deinit();
                    continue;
                }
                if (blocks.items.len == 1) {
                    const tb = try gpa.create(TopBlock);
                    tb.* = .{ .refs = .init(1), .arena = arena, .range = range, .block = blocks.items[0] };
                    try out.append(gpa, tb);
                } else {
                    // Several blocks from one transparent container: each top
                    // block gets its own deep copy so arenas stay per-block.
                    for (blocks.items) |blk| {
                        const tb = try TopBlock.create(gpa);
                        tb.range = range;
                        tb.block = try deepCopyBlock(tb.arena.allocator(), blk);
                        try out.append(gpa, tb);
                    }
                    arena.deinit();
                }
            },
            // Stray inline events at top level (shouldn't happen): skip.
            else => cur.bump(),
        }
    }
}

fn deepCopyRuns(a: Allocator, runs: []const InlineRun) Allocator.Error![]const InlineRun {
    const out = try a.alloc(InlineRun, runs.len);
    for (runs, out) |r, *o| {
        o.* = r;
        o.text = try a.dupe(u8, r.text);
        if (r.style.link) |l| o.style.link = try a.dupe(u8, l);
        if (r.style.file_label) |l| o.style.file_label = try a.dupe(u8, l);
        if (r.style.image) |img| o.style.image = .{
            .source = try a.dupe(u8, img.source),
            .alt = try a.dupe(u8, img.alt),
            .title = try a.dupe(u8, img.title),
            .link = if (img.link) |l| try a.dupe(u8, l) else null,
        };
    }
    return out;
}

fn deepCopyCells(a: Allocator, cells: []const []const InlineRun) Allocator.Error![]const []const InlineRun {
    const out = try a.alloc([]const InlineRun, cells.len);
    for (cells, out) |c, *o| o.* = try deepCopyRuns(a, c);
    return out;
}

pub fn deepCopyBlock(a: Allocator, b: Block) Allocator.Error!Block {
    return switch (b) {
        .paragraph => |r| .{ .paragraph = try deepCopyRuns(a, r) },
        .heading => |h| .{ .heading = .{ .level = h.level, .runs = try deepCopyRuns(a, h.runs) } },
        .code_block => |c| .{ .code_block = .{
            .language = if (c.language) |l| try a.dupe(u8, l) else null,
            .code = try a.dupe(u8, c.code),
        } },
        .block_quote => |ch| blk: {
            const out = try a.alloc(Block, ch.len);
            for (ch, out) |x, *o| o.* = try deepCopyBlock(a, x);
            break :blk .{ .block_quote = out };
        },
        .list => |l| blk: {
            const items = try a.alloc([]const Block, l.items.len);
            for (l.items, items) |it, *o| {
                const bs = try a.alloc(Block, it.len);
                for (it, bs) |x, *y| y.* = try deepCopyBlock(a, x);
                o.* = bs;
            }
            break :blk .{ .list = .{ .ordered_start = l.ordered_start, .items = items } };
        },
        .table => |t| blk: {
            const rows = try a.alloc([]const []const InlineRun, t.rows.len);
            for (t.rows, rows) |r, *o| o.* = try deepCopyCells(a, r);
            break :blk .{ .table = .{
                .header = try deepCopyCells(a, t.header),
                .rows = rows,
                .alignment = try a.dupe(TableAlign, t.alignment),
            } };
        },
        .rule => .rule,
    };
}

// ---------------------------------------------------------------------------
// Absolute destinations with spaces → angle-bracket form
// ---------------------------------------------------------------------------

/// Wrap inline link/image destinations that spell an absolute path with
/// literal spaces in angle brackets (CommonMark ends a destination at its
/// first space). Code keeps its spelling; already-bracketed or unclosed
/// destinations are left alone. Returns null when nothing changed.
fn rewriteAbsoluteDestinations(a: Allocator, source: []const u8, insertions: *Insertions) Allocator.Error!?[]const u8 {
    if (std.mem.indexOf(u8, source, "](") == null) return null;
    const bytes = source;
    var rewritten: ?std.ArrayList(u8) = null;
    var copied: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        if (at == 0 or bytes[at - 1] == '\n') {
            if (fenceOpen(source[at..])) |fence| {
                const end = skipFencedBlock(source, at, fence);
                try skipRegion(a, &rewritten, source, &copied, end);
                at = end;
                continue;
            }
            if (lineIsIndentedCode(source[at..])) {
                const end = lineEnd(source, at);
                try skipRegion(a, &rewritten, source, &copied, end);
                at = end;
                continue;
            }
        }
        switch (bytes[at]) {
            '`' => {
                if (isEscaped(bytes, at)) {
                    at += 1;
                    continue;
                }
                const run = backtickRun(bytes, at);
                const end = if (closingBacktickRun(bytes, at + run, run)) |close| close + run else at + run;
                try skipRegion(a, &rewritten, source, &copied, end);
                at = end;
            },
            ']' => {
                if (!(at + 1 < bytes.len and bytes[at + 1] == '(') or isEscaped(bytes, at)) {
                    at += 1;
                    continue;
                }
                const start = skipDestinationSpaces(bytes, at + 2);
                const close = destinationClose(bytes, start) orelse {
                    at += 2;
                    continue;
                };
                const destination = std.mem.trimEnd(u8, source[start..close], " ");
                if (absoluteDestinationWithSpaces(destination)) {
                    if (rewritten == null) {
                        var o: std.ArrayList(u8) = .empty;
                        try o.ensureTotalCapacity(a, source.len + 8);
                        try o.appendSlice(a, source[0..copied]);
                        rewritten = o;
                    }
                    const out = &rewritten.?;
                    try out.appendSlice(a, source[copied..start]);
                    try insertions.positions.append(a, out.items.len);
                    try out.append(a, '<');
                    try out.appendSlice(a, destination);
                    try insertions.positions.append(a, out.items.len);
                    try out.append(a, '>');
                    copied = start + destination.len;
                }
                at = close + 1;
            },
            else => at += 1,
        }
    }
    var out = rewritten orelse return null;
    try out.appendSlice(a, source[copied..]);
    return out.items;
}

fn skipRegion(a: Allocator, rewritten: *?std.ArrayList(u8), source: []const u8, copied: *usize, until: usize) Allocator.Error!void {
    if (rewritten.*) |*out| try out.appendSlice(a, source[copied.*..until]);
    copied.* = until;
}

fn absoluteDestinationWithSpaces(destination: []const u8) bool {
    if (std.mem.indexOfScalar(u8, destination, ' ') == null) return false;
    var path: []const u8 = undefined;
    const is_file_url = std.mem.startsWith(u8, destination, "file://");
    if (is_file_url) {
        const rest = destination["file://".len..];
        const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (host_end != 0) return false;
        path = rest[host_end..];
    } else if (std.mem.startsWith(u8, destination, "/")) {
        path = destination;
    } else return false;
    if (path.len <= 1 or std.mem.startsWith(u8, path, "//") or std.mem.endsWith(u8, path, "/") or
        std.mem.indexOfAny(u8, destination, "\\?") != null) return false;
    // char::is_control: C0, DEL and C1 controls.
    var ci: usize = 0;
    while (ci < destination.len) {
        const d = unicode.decodeFirst(destination[ci..]).?;
        if (d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0)) return false;
        ci += d.len;
    }
    var parts = std.mem.splitScalar(u8, destination, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    const file_name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    return is_file_url or std.mem.indexOfScalar(u8, file_name, '.') != null;
}

fn fenceOpen(line: []const u8) ?struct { u8, usize } {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') indent += 1;
    if (indent > 3) return null;
    if (indent >= line.len) return null;
    const fence = line[indent];
    if (!(fence == '`' or fence == '~')) return null;
    var len: usize = 0;
    while (indent + len < line.len and line[indent + len] == fence) len += 1;
    if (len >= 3) return .{ fence, len };
    return null;
}

fn skipFencedBlock(source: []const u8, at: usize, fence: struct { u8, usize }) usize {
    const bytes = source;
    var cursor = lineEnd(source, at);
    while (cursor < bytes.len) {
        const end = lineEnd(source, cursor);
        const line = bytes[cursor..end];
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent <= 3) {
            var run: usize = 0;
            while (indent + run < line.len and line[indent + run] == fence[0]) run += 1;
            const rest = if (indent + run <= line.len) line[indent + run ..] else line[0..0];
            var all_ws = true;
            for (rest) |b| {
                if (!(b == ' ' or b == '\n' or b == '\r')) {
                    all_ws = false;
                    break;
                }
            }
            if (run >= fence[1] and all_ws) return end;
        }
        cursor = end;
    }
    return bytes.len;
}

fn lineIsIndentedCode(line: []const u8) bool {
    if (line.len > 0 and line[0] == '\t') return true;
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n >= 4;
}

fn lineEnd(source: []const u8, at: usize) usize {
    return if (std.mem.indexOfScalar(u8, source[at..], '\n')) |run| at + run + 1 else source.len;
}

fn isEscaped(bytes: []const u8, at: usize) bool {
    var n: usize = 0;
    while (n < at and bytes[at - 1 - n] == '\\') n += 1;
    return n % 2 == 1;
}

fn backtickRun(bytes: []const u8, at: usize) usize {
    var n: usize = 0;
    while (at + n < bytes.len and bytes[at + n] == '`') n += 1;
    return n;
}

fn closingBacktickRun(bytes: []const u8, from: usize, run: usize) ?usize {
    var at = from;
    while (at < bytes.len) {
        if (bytes[at] == '`') {
            const len = backtickRun(bytes, at);
            if (len == run) return at;
            at += len;
        } else at += 1;
    }
    return null;
}

fn skipDestinationSpaces(bytes: []const u8, at_in: usize) usize {
    var at = at_in;
    while (at < bytes.len and bytes[at] == ' ') at += 1;
    return at;
}

fn destinationClose(bytes: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var at = start;
    while (at < bytes.len) {
        switch (bytes[at]) {
            '\\' => at += 2,
            '(' => {
                depth += 1;
                at += 1;
            },
            ')' => {
                if (depth == 0) return at;
                depth -= 1;
                at += 1;
            },
            else => |b| {
                if (b < 0x20 or b == 0x7f) return null;
                at += 1;
            },
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Event → block conversion
// ---------------------------------------------------------------------------

const Cursor = struct {
    events: []const OffsetEvent,
    ix: usize = 0,

    fn peek(self: *const Cursor) ?OffsetEvent {
        return if (self.ix < self.events.len) self.events[self.ix] else null;
    }

    fn bump(self: *Cursor) void {
        self.ix += 1;
    }

    fn nextEvent(self: *Cursor) ?OffsetEvent {
        const e = self.peek() orelse return null;
        self.ix += 1;
        return e;
    }
};

fn isBlockTag(tag: cmark.Tag) bool {
    return switch (tag) {
        .paragraph, .heading, .code_block, .block_quote, .list, .item, .table, .html_block => true,
        else => false,
    };
}

/// Runs being built: texts are owned slices in the block arena.
const RunList = std.ArrayList(InlineRun);

const Builder = struct {
    a: Allocator,

    /// Consume a `Start(tag)` and everything through its matching `End`.
    fn parseStartedBlock(self: *Builder, cur: *Cursor, out: *std.ArrayList(Block)) Allocator.Error!void {
        const oe = cur.nextEvent() orelse return;
        if (oe.event != .start) return;
        const tag = oe.event.start;
        switch (tag) {
            .paragraph => try out.append(self.a, .{ .paragraph = try self.parseInlineContainer(cur, .{}) }),
            .heading => |level| try out.append(self.a, .{ .heading = .{ .level = level, .runs = try self.parseInlineContainer(cur, .{}) } }),
            .code_block => |kind| {
                var language: ?[]const u8 = null;
                if (kind) |info| {
                    if (firstWhitespaceToken(info)) |lang| language = try self.a.dupe(u8, lang);
                }
                var code: std.ArrayList(u8) = .empty;
                while (cur.nextEvent()) |e| {
                    switch (e.event) {
                        .text => |t| try code.appendSlice(self.a, t),
                        .end => break,
                        else => {},
                    }
                }
                var c = code.items;
                if (c.len > 0 and c[c.len - 1] == '\n') c = c[0 .. c.len - 1];
                try out.append(self.a, .{ .code_block = .{ .language = language, .code = c } });
            },
            .block_quote => {
                var children: std.ArrayList(Block) = .empty;
                try self.parseBlockSequence(cur, &children);
                try out.append(self.a, .{ .block_quote = children.items });
            },
            .list => |ordered_start| {
                var items: std.ArrayList([]const Block) = .empty;
                while (true) {
                    const p = cur.peek() orelse {
                        cur.bump();
                        break;
                    };
                    if (p.event == .start and p.event.start == .item) {
                        cur.bump();
                        var seq: std.ArrayList(Block) = .empty;
                        try self.parseBlockSequence(cur, &seq);
                        try items.append(self.a, seq.items);
                    } else if (p.event == .end) {
                        cur.bump();
                        break;
                    } else cur.bump();
                }
                try out.append(self.a, .{ .list = .{ .ordered_start = ordered_start, .items = items.items } });
            },
            .table => |aligns| {
                const alignment = try self.a.alloc(TableAlign, aligns.len);
                for (aligns, alignment) |x, *y| y.* = switch (x) {
                    .center => .center,
                    .right => .right,
                    .none, .left => .left,
                };
                try out.append(self.a, try self.parseTable(cur, alignment));
            },
            .html_block => {
                var text: std.ArrayList(u8) = .empty;
                while (cur.nextEvent()) |e| {
                    switch (e.event) {
                        .html, .text => |t| try text.appendSlice(self.a, t),
                        .end => break,
                        else => {},
                    }
                }
                const t = std.mem.trimEnd(u8, text.items, "\n");
                if (t.len != 0) {
                    const runs = try self.a.alloc(InlineRun, 1);
                    runs[0] = .{ .text = t };
                    try out.append(self.a, .{ .paragraph = runs });
                }
            },
            // Transparent containers.
            else => try self.parseBlockSequence(cur, out),
        }
    }

    /// Parse a block sequence until the container's `End` (consumed). Bare
    /// inline events (tight list items) accumulate into an implicit paragraph.
    fn parseBlockSequence(self: *Builder, cur: *Cursor, out: *std.ArrayList(Block)) Allocator.Error!void {
        var acc: RunList = .empty;
        while (cur.peek()) |p| {
            switch (p.event) {
                .end => {
                    cur.bump();
                    break;
                },
                .start => |tag| if (isBlockTag(tag)) {
                    try self.flushParagraph(out, &acc);
                    try self.parseStartedBlock(cur, out);
                } else {
                    try self.parseInlineEvent(cur, &acc, .{});
                },
                .rule => {
                    try self.flushParagraph(out, &acc);
                    cur.bump();
                    try out.append(self.a, .rule);
                },
                else => try self.parseInlineEvent(cur, &acc, .{}),
            }
        }
        try self.flushParagraph(out, &acc);
    }

    fn flushParagraph(self: *Builder, out: *std.ArrayList(Block), acc: *RunList) Allocator.Error!void {
        if (acc.items.len != 0) {
            const merged = try mergeRuns(self.a, acc.items);
            acc.* = .empty;
            try out.append(self.a, .{ .paragraph = merged });
        }
    }

    fn parseTable(self: *Builder, cur: *Cursor, alignment: []TableAlign) Allocator.Error!Block {
        var header: []const []const InlineRun = &.{};
        var rows: std.ArrayList([]const []const InlineRun) = .empty;
        while (true) {
            const p = cur.peek() orelse {
                cur.bump();
                break;
            };
            if (p.event == .start and p.event.start == .table_head) {
                cur.bump();
                header = try self.parseTableCells(cur);
            } else if (p.event == .start and p.event.start == .table_row) {
                cur.bump();
                try rows.append(self.a, try self.parseTableCells(cur));
            } else if (p.event == .end) {
                cur.bump();
                break;
            } else cur.bump();
        }
        return .{ .table = .{ .header = header, .rows = rows.items, .alignment = alignment } };
    }

    fn parseTableCells(self: *Builder, cur: *Cursor) Allocator.Error![]const []const InlineRun {
        var cells: std.ArrayList([]const InlineRun) = .empty;
        while (true) {
            const p = cur.peek() orelse {
                cur.bump();
                break;
            };
            if (p.event == .start and p.event.start == .table_cell) {
                cur.bump();
                try cells.append(self.a, try self.parseInlineContainer(cur, .{}));
            } else if (p.event == .end) {
                cur.bump();
                break;
            } else cur.bump();
        }
        return cells.items;
    }

    /// Parse inline events until the container's `End` (consumed). Autolink
    /// after merging (pulldown splits Text at would-be emphasis chars).
    fn parseInlineContainer(self: *Builder, cur: *Cursor, style: InlineStyle) Allocator.Error![]const InlineRun {
        var runs: RunList = .empty;
        while (cur.peek()) |p| {
            if (p.event == .end) {
                cur.bump();
                break;
            }
            try self.parseInlineEvent(cur, &runs, style);
        }
        const merged = try mergeRuns(self.a, runs.items);
        return autolinkRuns(self.a, merged);
    }

    fn pushRun(self: *Builder, runs: *RunList, text: []const u8, style: InlineStyle) Allocator.Error!void {
        if (text.len != 0) try runs.append(self.a, .{ .text = try self.a.dupe(u8, text), .style = style });
    }

    fn parseInlineEvent(self: *Builder, cur: *Cursor, runs: *RunList, style: InlineStyle) Allocator.Error!void {
        const oe = cur.nextEvent() orelse return;
        switch (oe.event) {
            .text => |t| try self.pushRun(runs, t, style),
            .code => |t| {
                var s = style;
                s.code = true;
                try self.pushRun(runs, t, s);
            },
            .soft_break => try self.pushRun(runs, " ", style),
            .hard_break => try self.pushRun(runs, "\n", style),
            .html, .inline_html => |t| try self.pushRun(runs, t, style),
            .task_list_marker => |done| {
                var s = style;
                s.task = .{ .checked = done, .range = .{ .start = oe.start, .end = oe.end } };
                try self.pushRun(runs, if (done) "[x] " else "[ ] ", s);
            },
            .start => |tag| {
                var inner = style;
                switch (tag) {
                    .emphasis => inner.italic = true,
                    .strong => inner.bold = true,
                    .strikethrough => inner.strikethrough = true,
                    .image => |img| {
                        const alt_runs = try self.parseInlineContainer(cur, style);
                        var alt: std.ArrayList(u8) = .empty;
                        for (alt_runs) |r| try alt.appendSlice(self.a, r.text);
                        const dest = try self.a.dupe(u8, img.dest_url);
                        inner.image = .{
                            .source = dest,
                            .alt = alt.items,
                            .title = try self.a.dupe(u8, img.title),
                            .link = style.link,
                        };
                        inner.link = dest;
                        try runs.append(self.a, .{ .text = alt.items, .style = inner });
                        return;
                    },
                    .link => |l| inner.link = try self.a.dupe(u8, l.dest_url),
                    else => {},
                }
                const sub = try self.parseInlineContainer(cur, inner);
                try runs.appendSlice(self.a, sub);
            },
            else => {},
        }
    }
};

/// First token of `info` split on Unicode whitespace (`split_whitespace`).
fn firstWhitespaceToken(info: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < info.len) {
        const d = unicode.decodeFirst(info[i..]).?;
        if (!unicode.isWhitespace(d.cp)) break;
        i += d.len;
    }
    const start = i;
    while (i < info.len) {
        const d = unicode.decodeFirst(info[i..]).?;
        if (unicode.isWhitespace(d.cp)) break;
        i += d.len;
    }
    if (i == start) return null;
    return info[start..i];
}

/// Merge adjacent identically-styled runs (images never merge).
fn mergeRuns(a: Allocator, runs: []const InlineRun) Allocator.Error![]const InlineRun {
    var out: RunList = .empty;
    try out.ensureTotalCapacity(a, runs.len);
    for (runs) |run| {
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.style.eql(run.style) and run.style.image == null) {
                last.text = try std.mem.concat(a, u8, &.{ last.text, run.text });
                continue;
            }
        }
        out.appendAssumeCapacity(run);
    }
    return out.items;
}

/// Promote bare `http(s)://` URLs into link runs (GFM's autolink extension,
/// which pulldown-cmark lacks). Runs inside a link or code pass through.
fn autolinkRuns(a: Allocator, runs: []const InlineRun) Allocator.Error![]const InlineRun {
    var out: RunList = .empty;
    try out.ensureTotalCapacity(a, runs.len);
    for (runs) |run| {
        if (run.style.link != null or run.style.code) {
            try out.append(a, run);
        } else {
            try pushTextAutolinked(a, &out, run.text, run.style);
        }
    }
    return out.items;
}

fn pushTextAutolinked(a: Allocator, runs: *RunList, text: []const u8, style: InlineStyle) Allocator.Error!void {
    var rest = text;
    while (findUrlStart(rest)) |at| {
        const from = rest[at..];
        const scheme: usize = if (std.mem.startsWith(u8, from, "https://")) "https://".len else "http://".len;
        const len = bareUrlLen(from);
        if (len <= scheme) {
            if (at + scheme > 0) try runs.append(a, .{ .text = rest[0 .. at + scheme], .style = style });
            rest = from[scheme..];
            continue;
        }
        if (at > 0) try runs.append(a, .{ .text = rest[0..at], .style = style });
        var linked = style;
        linked.link = from[0..len];
        try runs.append(a, .{ .text = from[0..len], .style = linked });
        rest = from[len..];
    }
    if (rest.len > 0) try runs.append(a, .{ .text = rest, .style = style });
}

/// First viable `http(s)://`: not glued to a preceding alphanumeric.
fn findUrlStart(text: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOf(u8, text[from..], "http")) |rel| {
        const at = from + rel;
        const after = text[at..];
        const is_scheme = std.mem.startsWith(u8, after, "http://") or std.mem.startsWith(u8, after, "https://");
        const boundary = if (unicode.decodeLast(text[0..at])) |d| !unicode.isAlphanumeric(d.cp) else true;
        if (is_scheme and boundary) return at;
        from = at + "http".len;
    }
    return null;
}

/// Byte length of the bare URL at the start of `text`.
fn bareUrlLen(text: []const u8) usize {
    var end: usize = text.len;
    var i: usize = 0;
    while (i < text.len) {
        const d = unicode.decodeFirst(text[i..]).?;
        if (unicode.isWhitespace(d.cp) or d.cp == '<' or d.cp == '>' or d.cp == '"' or d.cp == '\'' or d.cp == '`') {
            end = i;
            break;
        }
        i += d.len;
    }
    var url = text[0..end];
    while (unicode.decodeLast(url)) |last| {
        const trim = switch (last.cp) {
            '.', ',', ';', ':', '!', '?', '*', '_', '~' => true,
            ')' => std.mem.count(u8, url, "(") < std.mem.count(u8, url, ")"),
            else => false,
        };
        if (!trim) break;
        url = url[0 .. url.len - last.len];
    }
    return url.len;
}

// ---------------------------------------------------------------------------
// Incremental parse
// ---------------------------------------------------------------------------

/// Streaming parser: appends reparse only from the last stable top-level
/// block boundary (snapped back to a line start).
pub const IncrementalParser = struct {
    gpa: Allocator,
    source: std.ArrayList(u8) = .empty,
    tree: BlockTree = .{},
    /// Display-only replacement for the last top-level block when its
    /// source has hanging inline markers; null = display tree is `tree`.
    display_tail: ?[]*TopBlock = null,
    /// Link-reference definitions act at a distance — full reparses only.
    full_only: bool = false,
    /// Bytes reparsed by the most recent update (O(tail) instrumentation).
    last_parse_bytes: usize = 0,
    /// Leading top-level blocks guaranteed untouched by the last update.
    stable_prefix_blocks: usize = 0,

    pub fn init(gpa: Allocator) IncrementalParser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *IncrementalParser) void {
        self.clearDisplayTail();
        self.tree.deinit(self.gpa);
        self.source.deinit(self.gpa);
    }

    pub fn sourceText(self: *const IncrementalParser) []const u8 {
        return self.source.items;
    }

    /// The canonical tree (borrowed; `clone` it to keep a snapshot).
    pub fn canonical(self: *const IncrementalParser) BlockTree {
        return self.tree;
    }

    /// The tree to render while streaming: canonical tree with the last
    /// block swapped for its mended parse. Caller owns the returned handle.
    pub fn displayTree(self: *const IncrementalParser) Allocator.Error!BlockTree {
        const tail = self.display_tail orelse return self.tree.clone(self.gpa);
        const stable = self.tree.blocks[0 .. self.tree.blocks.len - 1];
        const out = try self.gpa.alloc(*TopBlock, stable.len + tail.len);
        for (stable, 0..) |b, i| out[i] = b.retain();
        for (tail, 0..) |b, i| out[stable.len + i] = b.retain();
        return .{ .blocks = out };
    }

    pub fn lastParseBytes(self: *const IncrementalParser) usize {
        return self.last_parse_bytes;
    }

    pub fn stablePrefixBlocks(self: *const IncrementalParser) usize {
        return self.stable_prefix_blocks;
    }

    /// Set the source: appends take the incremental path, anything else resets.
    pub fn setText(self: *IncrementalParser, text: []const u8) Allocator.Error!void {
        if (text.len >= self.source.items.len and std.mem.startsWith(u8, text, self.source.items)) {
            const delta = text[self.source.items.len..];
            if (delta.len == 0) {
                self.last_parse_bytes = 0;
                self.stable_prefix_blocks = self.tree.blocks.len;
                return;
            }
            try self.append(delta);
        } else {
            try self.reset(text);
        }
    }

    pub fn reset(self: *IncrementalParser, text: []const u8) Allocator.Error!void {
        self.source.clearRetainingCapacity();
        try self.source.appendSlice(self.gpa, text);
        self.full_only = hasLinkDefs(text);
        const t = try parseFull(self.gpa, self.source.items);
        self.tree.deinit(self.gpa);
        self.tree = t;
        self.last_parse_bytes = text.len;
        self.stable_prefix_blocks = 0;
        try self.remend();
    }

    /// Append streamed text, reparsing from the last stable boundary.
    pub fn append(self: *IncrementalParser, delta: []const u8) Allocator.Error!void {
        if (delta.len == 0) {
            self.last_parse_bytes = 0;
            self.stable_prefix_blocks = self.tree.blocks.len;
            return;
        }
        const scan_from = if (std.mem.lastIndexOfScalar(u8, self.source.items, '\n')) |i| i + 1 else 0;
        try self.source.appendSlice(self.gpa, delta);
        if (!self.full_only and hasLinkDefs(self.source.items[scan_from..])) self.full_only = true;
        if (self.full_only) {
            const t = try parseFull(self.gpa, self.source.items);
            self.tree.deinit(self.gpa);
            self.tree = t;
            self.last_parse_bytes = self.source.items.len;
            self.stable_prefix_blocks = 0;
            try self.remend();
            return;
        }

        // Stable boundary: start of the SECOND-to-last top-level block,
        // snapped back to its line start (two blocks cover continuation
        // merges such as `3` → `3.` fusing into a preceding loose list).
        const n = self.tree.blocks.len;
        var boundary: usize = if (n <= 1) 0 else self.tree.blocks[n - 2].range.start;
        boundary = if (std.mem.lastIndexOfScalar(u8, self.source.items[0..boundary], '\n')) |i| i + 1 else 0;

        var tail: std.ArrayList(*TopBlock) = .empty;
        defer tail.deinit(self.gpa);
        errdefer for (tail.items) |b| b.release();
        try parseAt(self.gpa, self.source.items[boundary..], boundary, &tail);
        self.last_parse_bytes = self.source.items.len - boundary;

        var kept: usize = 0;
        for (self.tree.blocks) |b| {
            if (b.range.start < boundary) {
                self.tree.blocks[kept] = b;
                kept += 1;
            } else b.release();
        }
        self.stable_prefix_blocks = kept;
        const blocks = try self.gpa.alloc(*TopBlock, kept + tail.items.len);
        @memcpy(blocks[0..kept], self.tree.blocks[0..kept]);
        @memcpy(blocks[kept..], tail.items);
        tail.clearRetainingCapacity();
        self.gpa.free(self.tree.blocks);
        self.tree.blocks = blocks;
        try self.remend();
    }

    fn clearDisplayTail(self: *IncrementalParser) void {
        if (self.display_tail) |t| {
            for (t) |b| b.release();
            self.gpa.free(t);
            self.display_tail = null;
        }
    }

    /// Recompute the display tail: mend hanging inline markers in the last
    /// top-level block and reparse just that block's source.
    fn remend(self: *IncrementalParser) Allocator.Error!void {
        self.clearDisplayTail();
        if (self.tree.blocks.len == 0) return;
        const last = self.tree.blocks[self.tree.blocks.len - 1];
        switch (last.block) {
            .code_block, .rule, .table => return,
            else => {},
        }
        const start = last.range.start;
        const mended = (try mend.closeHanging(self.gpa, self.source.items[start..])) orelse return;
        defer self.gpa.free(mended);
        self.last_parse_bytes += mended.len;
        var tail: std.ArrayList(*TopBlock) = .empty;
        errdefer {
            for (tail.items) |b| b.release();
            tail.deinit(self.gpa);
        }
        try parseAt(self.gpa, mended, start, &tail);
        for (tail.items) |top| top.range.end = @min(top.range.end, self.source.items.len);
        self.display_tail = try tail.toOwnedSlice(self.gpa);
    }
};

/// Conservative detector for link-reference-definition lines
/// (`[label]: destination`, up to 3 leading spaces).
pub fn hasLinkDefs(text: []const u8) bool {
    var it = LineIter{ .s = text };
    while (it.next()) |line| {
        const trimmed = trimStartUnicode(line);
        if (line.len - trimmed.len <= 3 and trimmed.len > 0 and trimmed[0] == '[' and std.mem.indexOf(u8, trimmed, "]:") != null) return true;
    }
    return false;
}

pub const LineIter = unicode.LineIter;
pub const trimStartUnicode = unicode.trimStart;
pub const trimEndUnicode = unicode.trimEnd;
pub const trimUnicode = unicode.trim;
