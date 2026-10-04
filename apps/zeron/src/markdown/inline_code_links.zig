//! File links written as inline code — the tree rewrite of
//! `zeron_ui::markdown::inline_code_links`.
//!
//! Agents name files in code spans ("all under `dir/`:" then bare
//! `SOURCES.md`). A span whose text resolves to an existing file is rewritten
//! into the link it stands for (`code` off, `link` = target, `file_label` =
//! its file name, or as many trailing components as it takes to tell two
//! different paths with the same name apart). Directory spans become context
//! for later bare names in the same part.
//!
//! Path probing is the host's business (workspace roots, the filesystem):
//! it plugs in through `Resolver`, which receives the span text and the
//! directory context collected so far in document order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const parser = @import("parser.zig");

const Block = model.Block;
const BlockTree = model.BlockTree;
const InlineRun = model.InlineRun;
const TopBlock = model.TopBlock;

pub const Resolution = union(enum) {
    /// A link target (e.g. `file:///abs/path:12`).
    file: []const u8,
    /// A directory: context for later spans.
    directory: []const u8,
};

pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    /// Returned strings must stay valid for the duration of `linkTree`.
    func: *const fn (ctx: ?*anyopaque, span: []const u8, context_dirs: []const []const u8) ?Resolution,

    fn call(self: Resolver, span: []const u8, dirs: []const []const u8) ?Resolution {
        return self.func(self.ctx, span, dirs);
    }
};

/// Only a plain code span stands for a file.
fn isPlainCodeSpan(run: InlineRun) bool {
    return run.style.code and run.style.link == null and run.style.image == null and run.style.task == null;
}

fn codeSpans(a: Allocator, block: Block, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    const S = struct {
        fn push(al: Allocator, runs: []const InlineRun, o: *std.ArrayList([]const u8)) Allocator.Error!void {
            for (runs) |r| if (isPlainCodeSpan(r)) try o.append(al, r.text);
        }
    };
    switch (block) {
        .paragraph => |runs| try S.push(a, runs, out),
        .heading => |h| try S.push(a, h.runs, out),
        .table => |t| {
            for (t.header) |c| try S.push(a, c, out);
            for (t.rows) |row| for (row) |c| try S.push(a, c, out);
        },
        .block_quote => |ch| for (ch) |c| try codeSpans(a, c, out),
        .list => |l| for (l.items) |it| for (it) |c| try codeSpans(a, c, out),
        .code_block, .rule => {},
    }
}

/// The last `components` path components of `span` (all of it when fewer).
fn trailing(span: []const u8, components: usize) []const u8 {
    var count: usize = 0;
    var i = span.len;
    while (i > 0) {
        i -= 1;
        if (span[i] == '/') {
            count += 1;
            if (count == components) return span[i + 1 ..];
        }
    }
    return span;
}

pub fn fileName(span: []const u8) []const u8 {
    return trailing(span, 1);
}

// --- location suffix handling (workspace_links.rs) -------------------------

fn parseU32(s: []const u8) ?u32 {
    var t = s;
    if (t.len > 0 and t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

fn positiveNumber(v: []const u8) ?u32 {
    const n = parseU32(v) orelse return null;
    return if (n > 0) n else null;
}

const LineAnchor = enum { none, line, invalid };

fn parseLineColumn(value: []const u8) ?struct { u32, ?u32 } {
    if (std.mem.indexOfScalar(u8, value, 'C')) |c| {
        return .{ parseU32(value[0..c]) orelse return null, parseU32(value[c + 1 ..]) orelse return null };
    }
    return .{ parseU32(value) orelse return null, null };
}

fn parseAnchor(fragment: []const u8) LineAnchor {
    if (fragment.len == 0 or fragment[0] != 'L') return .none;
    const rest = fragment[1..];
    var start_part = rest;
    var end_part: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '-')) |d| {
        start_part = rest[0..d];
        const e = rest[d + 1 ..];
        end_part = if (e.len > 0 and e[0] == 'L') e[1..] else e;
    }
    const lc = parseLineColumn(start_part) orelse return .none;
    if (lc[0] == 0 or lc[1] == 0) return .invalid;
    if (end_part) |ep| {
        const elc = parseLineColumn(ep) orelse return .none;
        if (elc[0] < lc[0] or elc[1] == 0) return .invalid;
    }
    return .line;
}

/// null = the target is not a file link at all.
fn splitLineFragment(target: []const u8) ?[]const u8 {
    const hash = std.mem.lastIndexOfScalar(u8, target, '#') orelse return target;
    const path = target[0..hash];
    const fragment = target[hash + 1 ..];
    if (fragment.len == 0) return path;
    if (std.mem.indexOfScalar(u8, fragment, '/') != null) return target;
    return switch (parseAnchor(fragment)) {
        .invalid => null,
        .none, .line => path,
    };
}

fn splitLineSuffix(target: []const u8) ?[]const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return target;
    const last = target[colon + 1 ..];
    if (std.mem.indexOfScalar(u8, last, '-')) |d| {
        const s = parseU32(last[0..d]);
        const e = parseU32(last[d + 1 ..]);
        if (s == null or e == null) return target;
        return if (s.? == 0 or e.? < s.?) null else target[0..colon];
    }
    if (parseU32(last)) |n| if (n == 0) return null;
    _ = positiveNumber(last) orelse return target;
    const before = target[0..colon];
    if (std.mem.lastIndexOfScalar(u8, before, ':')) |colon2| {
        if (positiveNumber(before[colon2 + 1 ..]) != null) return before[0..colon2];
        if (parseU32(before[colon2 + 1 ..])) |z| if (z == 0) return null;
        return before;
    }
    return before;
}

/// `target` without its `#L12` fragment or `:12` line suffix.
pub fn withoutLocation(target: []const u8) []const u8 {
    const p = splitLineFragment(target) orelse return target;
    return splitLineSuffix(p) orelse target;
}

// --- labels -----------------------------------------------------------------

pub const Labels = std.StringHashMapUnmanaged([]const u8);

/// Labels for spans whose file name a different path in the same part shares.
pub fn spanLabels(a: Allocator, spans: []const []const u8) Allocator.Error!Labels {
    var by_name: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (spans) |span| {
        const path = withoutLocation(span);
        const gop = try by_name.getOrPut(a, fileName(path));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        var dup = false;
        for (gop.value_ptr.items) |p| if (std.mem.eql(u8, p, path)) {
            dup = true;
        };
        if (!dup) try gop.value_ptr.append(a, path);
    }
    var labels: Labels = .empty;
    for (spans) |span| {
        const path = withoutLocation(span);
        const same = by_name.get(fileName(path)).?.items;
        if (same.len < 2) continue;
        var components: usize = 1;
        while (true) : (components += 1) {
            const tail = trailing(path, components);
            if (std.mem.eql(u8, tail, path)) break;
            var shared = false;
            for (same) |other| {
                if (std.mem.eql(u8, other, path)) continue;
                if (std.mem.endsWith(u8, other, tail)) {
                    const rest = other[0 .. other.len - tail.len];
                    if (rest.len == 0 or rest[rest.len - 1] == '/') shared = true;
                }
            }
            if (!shared) break;
        }
        try labels.put(a, span, trailing(span, components));
    }
    return labels;
}

// --- rewrite ----------------------------------------------------------------

const Ctx = struct {
    a: Allocator,
    resolver: Resolver,
    labels: *const Labels,
    dirs: *std.ArrayList([]const u8),
    tmp: Allocator,
};

fn linkRuns(c: *Ctx, runs: []const InlineRun) Allocator.Error!bool {
    var changed = false;
    const mut: []InlineRun = @constCast(runs);
    for (mut) |*run| {
        if (!isPlainCodeSpan(run.*)) continue;
        switch (c.resolver.call(run.text, c.dirs.items) orelse continue) {
            .file => |target| {
                run.style.code = false;
                run.style.link = try c.a.dupe(u8, target);
                const label = c.labels.get(run.text) orelse fileName(run.text);
                run.style.file_label = try c.a.dupe(u8, label);
                changed = true;
            },
            .directory => |dir| try c.dirs.append(c.tmp, try c.tmp.dupe(u8, dir)),
        }
    }
    return changed;
}

fn linkBlock(c: *Ctx, block: Block) Allocator.Error!bool {
    return switch (block) {
        .paragraph => |runs| linkRuns(c, runs),
        .heading => |h| linkRuns(c, h.runs),
        .block_quote => |ch| blk: {
            var changed = false;
            for (ch) |b| changed = (try linkBlock(c, b)) or changed;
            break :blk changed;
        },
        .list => |l| blk: {
            var changed = false;
            for (l.items) |it| for (it) |b| {
                changed = (try linkBlock(c, b)) or changed;
            };
            break :blk changed;
        },
        .table => |t| blk: {
            var changed = false;
            for (t.header) |cell| changed = (try linkRuns(c, cell)) or changed;
            for (t.rows) |row| for (row) |cell| {
                changed = (try linkRuns(c, cell)) or changed;
            };
            break :blk changed;
        },
        .code_block, .rule => false,
    };
}

/// `tree` with every inline code span that names an existing file
/// rewritten into its link. Unchanged top blocks are shared.
pub fn linkTree(gpa: Allocator, tree: BlockTree, resolver: Resolver) Allocator.Error!BlockTree {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    var spans: std.ArrayList([]const u8) = .empty;
    for (tree.blocks) |top| try codeSpans(tmp, top.block, &spans);
    const labels = try spanLabels(tmp, spans.items);
    var dirs: std.ArrayList([]const u8) = .empty;

    const out = try gpa.alloc(*TopBlock, tree.blocks.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |b| b.release();
        gpa.free(out);
    }
    for (tree.blocks) |top| {
        const fresh = try TopBlock.create(gpa);
        fresh.range = top.range;
        fresh.block = parser.deepCopyBlock(fresh.arena.allocator(), top.block) catch |e| {
            fresh.release();
            return e;
        };
        var ctx: Ctx = .{ .a = fresh.arena.allocator(), .resolver = resolver, .labels = &labels, .dirs = &dirs, .tmp = tmp };
        const changed = linkBlock(&ctx, fresh.block) catch |e| {
            fresh.release();
            return e;
        };
        if (changed) {
            out[done] = fresh;
        } else {
            fresh.release();
            out[done] = top.retain();
        }
        done += 1;
    }
    return .{ .blocks = out };
}

test "span labels grow only as far as a collision needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const labels = try spanLabels(arena.allocator(), &.{
        "a/x/mod.rs", "b/x/mod.rs", "mod.rs", "a/x/mod.rs:3", "/abs/c/mod.rs", "README.md", "README.md#L4",
    });
    try std.testing.expectEqualStrings("a/x/mod.rs", labels.get("a/x/mod.rs").?);
    try std.testing.expectEqualStrings("a/x/mod.rs:3", labels.get("a/x/mod.rs:3").?);
    try std.testing.expectEqualStrings("b/x/mod.rs", labels.get("b/x/mod.rs").?);
    try std.testing.expectEqualStrings("mod.rs", labels.get("mod.rs").?);
    try std.testing.expectEqualStrings("c/mod.rs", labels.get("/abs/c/mod.rs").?);
    try std.testing.expect(labels.get("README.md") == null);
    try std.testing.expect(labels.get("README.md#L4") == null);
}

test "linkTree rewrites resolved spans and shares untouched blocks" {
    const gpa = std.testing.allocator;
    var tree = try parser.parseFull(gpa, "all under `dir/`:\n\n- `SOURCES.md` and `missing.md`\n\nplain text\n");
    defer tree.deinit(gpa);
    const R = struct {
        fn f(_: ?*anyopaque, span: []const u8, dirs: []const []const u8) ?Resolution {
            if (std.mem.eql(u8, span, "dir/")) return .{ .directory = "/root/dir" };
            if (std.mem.eql(u8, span, "SOURCES.md") and dirs.len == 1) return .{ .file = "file:///root/dir/SOURCES.md" };
            return null;
        }
    };
    var linked = try linkTree(gpa, tree, .{ .func = R.f });
    defer linked.deinit(gpa);
    try std.testing.expect(linked.blocks[0] == tree.blocks[0]);
    try std.testing.expect(linked.blocks[2] == tree.blocks[2]);
    const runs = linked.blocks[1].block.list.items[0][0].paragraph;
    try std.testing.expectEqualStrings("SOURCES.md", runs[0].text);
    try std.testing.expect(!runs[0].style.code);
    try std.testing.expectEqualStrings("file:///root/dir/SOURCES.md", runs[0].style.link.?);
    try std.testing.expectEqualStrings("SOURCES.md", runs[0].style.file_label.?);
    try std.testing.expect(runs[2].style.code); // missing.md stays code
}
