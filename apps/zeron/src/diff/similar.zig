//! Text diffing — a semantic port of the `similar` 2.7.0 crate as zeron uses
//! it: `TextDiff::from_lines` / `from_words` / `from_chars` (Myers with
//! `Compact` + `Replace` post-processing, exactly `capture_diff_deadline`
//! without a deadline), `group_diff_ops`, `iter_changes`, and the `inline`
//! feature's `iter_inline_changes` (Patience over words for intra-line
//! emphasis).
//!
//! Tokens are interned to integer ids before diffing; `similar` does the
//! same (`IdentifyDistinct`) above 100 tokens, and equality — the only thing
//! the algorithms observe — is unchanged either way.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
    pub fn isEmpty(self: Range) bool {
        return !(self.start < self.end);
    }
};

pub const DiffTag = enum { equal, delete, insert, replace };
pub const ChangeTag = enum { equal, delete, insert };
pub const Algorithm = enum { myers, patience };

pub const DiffOp = union(DiffTag) {
    equal: struct { old_index: usize, new_index: usize, len: usize },
    delete: struct { old_index: usize, old_len: usize, new_index: usize },
    insert: struct { old_index: usize, new_index: usize, new_len: usize },
    replace: struct { old_index: usize, old_len: usize, new_index: usize, new_len: usize },

    pub fn tag(self: DiffOp) DiffTag {
        return std.meta.activeTag(self);
    }

    pub fn oldRange(self: DiffOp) Range {
        return switch (self) {
            .equal => |o| .{ .start = o.old_index, .end = o.old_index + o.len },
            .delete => |o| .{ .start = o.old_index, .end = o.old_index + o.old_len },
            .insert => |o| .{ .start = o.old_index, .end = o.old_index },
            .replace => |o| .{ .start = o.old_index, .end = o.old_index + o.old_len },
        };
    }

    pub fn newRange(self: DiffOp) Range {
        return switch (self) {
            .equal => |o| .{ .start = o.new_index, .end = o.new_index + o.len },
            .delete => |o| .{ .start = o.new_index, .end = o.new_index },
            .insert => |o| .{ .start = o.new_index, .end = o.new_index + o.new_len },
            .replace => |o| .{ .start = o.new_index, .end = o.new_index + o.new_len },
        };
    }

    fn isEmpty(self: DiffOp) bool {
        return self.oldRange().isEmpty() and self.newRange().isEmpty();
    }

    const Adj = struct { usize, bool };

    fn adjust(self: *DiffOp, off: Adj, ln: Adj) void {
        const modify = struct {
            fn f(v: *usize, adj: Adj) void {
                if (adj[1]) v.* -= adj[0] else v.* += adj[0];
            }
        }.f;
        switch (self.*) {
            .equal => |*o| {
                modify(&o.old_index, off);
                modify(&o.new_index, off);
                modify(&o.len, ln);
            },
            .delete => |*o| {
                modify(&o.old_index, off);
                modify(&o.old_len, ln);
                modify(&o.new_index, off);
            },
            .insert => |*o| {
                modify(&o.old_index, off);
                modify(&o.new_index, off);
                modify(&o.new_len, ln);
            },
            .replace => |*o| {
                modify(&o.old_index, off);
                modify(&o.old_len, ln);
                modify(&o.new_index, off);
                modify(&o.new_len, ln);
            },
        }
    }

    fn shiftLeft(self: *DiffOp, a: usize) void {
        self.adjust(.{ a, true }, .{ 0, false });
    }
    fn shiftRight(self: *DiffOp, a: usize) void {
        self.adjust(.{ a, false }, .{ 0, false });
    }
    fn growLeft(self: *DiffOp, a: usize) void {
        self.adjust(.{ a, true }, .{ a, false });
    }
    fn growRight(self: *DiffOp, a: usize) void {
        self.adjust(.{ 0, false }, .{ a, false });
    }
    fn shrinkLeft(self: *DiffOp, a: usize) void {
        self.adjust(.{ 0, false }, .{ a, true });
    }
    fn shrinkRight(self: *DiffOp, a: usize) void {
        self.adjust(.{ a, false }, .{ a, true });
    }
};

// ---------------------------------------------------------------------------
// Myers (algorithms/myers.rs)
// ---------------------------------------------------------------------------

const Seq = []const u32;

fn commonPrefixLen(old: Seq, old_range: Range, new: Seq, new_range: Range) usize {
    if (old_range.isEmpty() or new_range.isEmpty()) return 0;
    var n: usize = 0;
    while (old_range.start + n < old_range.end and new_range.start + n < new_range.end and
        new[new_range.start + n] == old[old_range.start + n]) n += 1;
    return n;
}

fn commonSuffixLen(old: Seq, old_range: Range, new: Seq, new_range: Range) usize {
    if (old_range.isEmpty() or new_range.isEmpty()) return 0;
    var n: usize = 0;
    while (n < old_range.len() and n < new_range.len() and
        new[new_range.end - 1 - n] == old[old_range.end - 1 - n]) n += 1;
    return n;
}

const V = struct {
    offset: isize,
    v: []usize,

    fn init(a: Allocator, max_d: usize) Allocator.Error!V {
        const v = try a.alloc(usize, 2 * max_d);
        @memset(v, 0);
        return .{ .offset = @intCast(max_d), .v = v };
    }
    inline fn at(self: *V, k: isize) *usize {
        return &self.v[@intCast(k + self.offset)];
    }
};

fn maxD(len1: usize, len2: usize) usize {
    return (len1 + len2 + 1) / 2 + 1;
}

/// Raw op sink (the `Compact` buffer / `NoFinishHook` pass-through).
const Ops = std.ArrayList(DiffOp);

const Sink = struct {
    a: Allocator,
    ops: *Ops,
    fn equal(self: Sink, o: usize, n: usize, len: usize) Allocator.Error!void {
        try self.ops.append(self.a, .{ .equal = .{ .old_index = o, .new_index = n, .len = len } });
    }
    fn delete(self: Sink, o: usize, len: usize, n: usize) Allocator.Error!void {
        try self.ops.append(self.a, .{ .delete = .{ .old_index = o, .old_len = len, .new_index = n } });
    }
    fn insert(self: Sink, o: usize, n: usize, len: usize) Allocator.Error!void {
        try self.ops.append(self.a, .{ .insert = .{ .old_index = o, .new_index = n, .new_len = len } });
    }
};

fn findMiddleSnake(old: Seq, old_range: Range, new: Seq, new_range: Range, vf: *V, vb: *V) ?struct { usize, usize } {
    const n = old_range.len();
    const m = new_range.len();
    const delta: isize = @as(isize, @intCast(n)) - @as(isize, @intCast(m));
    const odd = (delta & 1) == 1;
    vf.at(1).* = 0;
    vb.at(1).* = 0;
    const d_max = maxD(n, m);
    std.debug.assert(vf.v.len >= d_max and vb.v.len >= d_max);

    var d: isize = 0;
    while (d < @as(isize, @intCast(d_max))) : (d += 1) {
        // Forward path
        var k: isize = d;
        while (k >= -d) : (k -= 2) {
            var x: usize = if (k == -d or (k != d and vf.at(k - 1).* < vf.at(k + 1).*)) vf.at(k + 1).* else vf.at(k - 1).* + 1;
            const y: usize = @intCast(@as(isize, @intCast(x)) - k);
            const x0 = x;
            const y0 = y;
            if (x < old_range.len() and y < new_range.len()) {
                x += commonPrefixLen(old, .{ .start = old_range.start + x, .end = old_range.end }, new, .{ .start = new_range.start + y, .end = new_range.end });
            }
            vf.at(k).* = x;
            if (odd and @abs(k - delta) <= d - 1) {
                if (vf.at(k).* + vb.at(-(k - delta)).* >= n) {
                    return .{ x0 + old_range.start, y0 + new_range.start };
                }
            }
        }
        // Backward path
        k = d;
        while (k >= -d) : (k -= 2) {
            var x: usize = if (k == -d or (k != d and vb.at(k - 1).* < vb.at(k + 1).*)) vb.at(k + 1).* else vb.at(k - 1).* + 1;
            var y: usize = @intCast(@as(isize, @intCast(x)) - k);
            if (x < n and y < m) {
                const advance = commonSuffixLen(old, .{ .start = old_range.start, .end = old_range.start + n - x }, new, .{ .start = new_range.start, .end = new_range.start + m - y });
                x += advance;
                y += advance;
            }
            vb.at(k).* = x;
            if (!odd and @abs(k - delta) <= d) {
                if (vb.at(k).* + vf.at(-(k - delta)).* >= n) {
                    return .{ n - x + old_range.start, m - y + new_range.start };
                }
            }
        }
    }
    return null;
}

fn conquer(sink: Sink, old: Seq, old_range_in: Range, new: Seq, new_range_in: Range, vf: *V, vb: *V) Allocator.Error!void {
    var old_range = old_range_in;
    var new_range = new_range_in;
    const prefix = commonPrefixLen(old, old_range, new, new_range);
    if (prefix > 0) try sink.equal(old_range.start, new_range.start, prefix);
    old_range.start += prefix;
    new_range.start += prefix;

    const suffix = commonSuffixLen(old, old_range, new, new_range);
    const common_suffix = .{ old_range.end - suffix, new_range.end - suffix };
    old_range.end -= suffix;
    new_range.end -= suffix;

    if (old_range.isEmpty() and new_range.isEmpty()) {
        // Do nothing
    } else if (new_range.isEmpty()) {
        try sink.delete(old_range.start, old_range.len(), new_range.start);
    } else if (old_range.isEmpty()) {
        try sink.insert(old_range.start, new_range.start, new_range.len());
    } else if (findMiddleSnake(old, old_range, new, new_range, vf, vb)) |snake| {
        try conquer(sink, old, .{ .start = old_range.start, .end = snake[0] }, new, .{ .start = new_range.start, .end = snake[1] }, vf, vb);
        try conquer(sink, old, .{ .start = snake[0], .end = old_range.end }, new, .{ .start = snake[1], .end = new_range.end }, vf, vb);
    } else {
        try sink.delete(old_range.start, old_range.end - old_range.start, new_range.start);
        try sink.insert(old_range.start, new_range.start, new_range.end - new_range.start);
    }
    if (suffix > 0) try sink.equal(common_suffix[0], common_suffix[1], suffix);
}

/// `myers::diff` into a raw op sink (no finish).
fn myersDiff(a: Allocator, sink: Sink, old: Seq, old_range: Range, new: Seq, new_range: Range) Allocator.Error!void {
    const md = maxD(old_range.len(), new_range.len());
    var vb = try V.init(a, md);
    defer a.free(vb.v);
    var vf = try V.init(a, md);
    defer a.free(vf.v);
    try conquer(sink, old, old_range, new, new_range, &vf, &vb);
}

// ---------------------------------------------------------------------------
// Patience (algorithms/patience.rs)
// ---------------------------------------------------------------------------

/// Items occurring exactly once in `seq[range]`, by original index.
fn unique(a: Allocator, seq: Seq, range: Range) Allocator.Error![]usize {
    var by_item: std.AutoHashMapUnmanaged(u32, ?usize) = .empty;
    defer by_item.deinit(a);
    for (range.start..range.end) |index| {
        const gop = try by_item.getOrPut(a, seq[index]);
        if (!gop.found_existing) {
            gop.value_ptr.* = index;
        } else {
            gop.value_ptr.* = null;
        }
    }
    var rv: std.ArrayList(usize) = .empty;
    var it = by_item.valueIterator();
    while (it.next()) |v| if (v.*) |ix| try rv.append(a, ix);
    std.mem.sort(usize, rv.items, {}, std.sort.asc(usize));
    return rv.toOwnedSlice(a);
}

fn patienceDiff(a: Allocator, sink: Sink, old: Seq, old_range: Range, new: Seq, new_range: Range) Allocator.Error!void {
    const old_indexes = try unique(a, old, old_range);
    defer a.free(old_indexes);
    const new_indexes = try unique(a, new, new_range);
    defer a.free(new_indexes);
    // Myers over the unique items (compared by value).
    const ou = try a.alloc(u32, old_indexes.len);
    defer a.free(ou);
    for (old_indexes, ou) |ix, *o| o.* = old[ix];
    const nu = try a.alloc(u32, new_indexes.len);
    defer a.free(nu);
    for (new_indexes, nu) |ix, *o| o.* = new[ix];

    var unique_ops: Ops = .empty;
    defer unique_ops.deinit(a);
    try myersDiff(a, .{ .a = a, .ops = &unique_ops }, ou, .{ .start = 0, .end = ou.len }, nu, .{ .start = 0, .end = nu.len });

    var old_current = old_range.start;
    var new_current = new_range.start;
    // `Replace` forwards equal runs to `Patience::equal`; delete/insert/
    // replace are no-ops there.
    for (unique_ops.items) |op| {
        if (op != .equal) continue;
        const e = op.equal;
        for (0..e.len) |k| {
            const oi = e.old_index + k;
            const ni = e.new_index + k;
            const a0 = old_current;
            const b0 = new_current;
            while (old_current < old_indexes[oi] and new_current < new_indexes[ni] and new[new_current] == old[old_current]) {
                old_current += 1;
                new_current += 1;
            }
            if (old_current > a0) try sink.equal(a0, b0, old_current - a0);
            try myersDiff(a, sink, old, .{ .start = old_current, .end = old_indexes[oi] }, new, .{ .start = new_current, .end = new_indexes[ni] });
            old_current = old_indexes[oi];
            new_current = new_indexes[ni];
        }
    }
    // Patience::finish
    try myersDiff(a, sink, old, .{ .start = old_current, .end = old_range.end }, new, .{ .start = new_current, .end = new_range.end });
}

// ---------------------------------------------------------------------------
// Compact (algorithms/compact.rs)
// ---------------------------------------------------------------------------

fn cleanupDiffOps(a: Allocator, old: Seq, new: Seq, ops: *Ops) Allocator.Error!void {
    var pointer: usize = 0;
    while (pointer < ops.items.len) {
        if (ops.items[pointer] == .delete) {
            pointer = try shiftDiffOpsUp(a, ops, old, new, pointer);
            pointer = try shiftDiffOpsDown(a, ops, old, new, pointer);
        }
        pointer += 1;
    }
    pointer = 0;
    while (pointer < ops.items.len) {
        if (ops.items[pointer] == .insert) {
            pointer = try shiftDiffOpsUp(a, ops, old, new, pointer);
            pointer = try shiftDiffOpsDown(a, ops, old, new, pointer);
        }
        pointer += 1;
    }
}

fn shiftDiffOpsUp(a: Allocator, ops: *Ops, old: Seq, new: Seq, pointer_in: usize) Allocator.Error!usize {
    var pointer = pointer_in;
    while (pointer > 0 and pointer - 1 < ops.items.len) {
        const prev_op = ops.items[pointer - 1];
        const this_op = ops.items[pointer];
        const tt = this_op.tag();
        const pt = prev_op.tag();
        if ((tt == .insert or tt == .delete) and pt == .equal) {
            const suffix_len = commonSuffixLen(old, prev_op.oldRange(), new, this_op.newRange());
            if (suffix_len != 0) {
                if (pointer + 1 < ops.items.len and ops.items[pointer + 1] == .equal) {
                    ops.items[pointer + 1].growLeft(suffix_len);
                } else {
                    const len = if (tt == .insert) suffix_len else prev_op.oldRange().len() - suffix_len;
                    try ops.insert(a, pointer + 1, .{ .equal = .{
                        .old_index = prev_op.oldRange().end - suffix_len,
                        .new_index = this_op.newRange().end - suffix_len,
                        .len = len,
                    } });
                }
                ops.items[pointer].shiftLeft(suffix_len);
                ops.items[pointer - 1].shrinkLeft(suffix_len);
                if (ops.items[pointer - 1].isEmpty()) {
                    _ = ops.orderedRemove(pointer - 1);
                    pointer -= 1;
                }
            } else if (ops.items[pointer - 1].isEmpty()) {
                _ = ops.orderedRemove(pointer - 1);
                pointer -= 1;
            } else break;
        } else if ((tt == .insert and pt == .delete) or (tt == .delete and pt == .insert)) {
            std.mem.swap(DiffOp, &ops.items[pointer - 1], &ops.items[pointer]);
            pointer -= 1;
        } else if (tt == .insert and pt == .insert) {
            ops.items[pointer - 1].growRight(this_op.newRange().len());
            _ = ops.orderedRemove(pointer);
            pointer -= 1;
        } else if (tt == .delete and pt == .delete) {
            ops.items[pointer - 1].growRight(this_op.oldRange().len());
            _ = ops.orderedRemove(pointer);
            pointer -= 1;
        } else unreachable;
    }
    return pointer;
}

fn shiftDiffOpsDown(a: Allocator, ops: *Ops, old: Seq, new: Seq, pointer_in: usize) Allocator.Error!usize {
    var pointer = pointer_in;
    while (pointer + 1 < ops.items.len) {
        const next_op = ops.items[pointer + 1];
        const this_op = ops.items[pointer];
        const tt = this_op.tag();
        const nt = next_op.tag();
        if ((tt == .insert or tt == .delete) and nt == .equal) {
            const prefix_len = commonPrefixLen(old, next_op.oldRange(), new, this_op.newRange());
            if (prefix_len > 0) {
                if (pointer > 0 and ops.items[pointer - 1] == .equal) {
                    ops.items[pointer - 1].growRight(prefix_len);
                } else {
                    try ops.insert(a, pointer, .{ .equal = .{
                        .old_index = next_op.oldRange().start,
                        .new_index = this_op.newRange().start,
                        .len = prefix_len,
                    } });
                    pointer += 1;
                }
                ops.items[pointer].shiftRight(prefix_len);
                ops.items[pointer + 1].shrinkRight(prefix_len);
                if (ops.items[pointer + 1].isEmpty()) _ = ops.orderedRemove(pointer + 1);
            } else if (ops.items[pointer + 1].isEmpty()) {
                _ = ops.orderedRemove(pointer + 1);
            } else break;
        } else if ((tt == .insert and nt == .delete) or (tt == .delete and nt == .insert)) {
            std.mem.swap(DiffOp, &ops.items[pointer], &ops.items[pointer + 1]);
            pointer += 1;
        } else if (tt == .insert and nt == .insert) {
            ops.items[pointer].growRight(next_op.newRange().len());
            _ = ops.orderedRemove(pointer + 1);
        } else if (tt == .delete and nt == .delete) {
            ops.items[pointer].growRight(next_op.oldRange().len());
            _ = ops.orderedRemove(pointer + 1);
        } else unreachable;
    }
    return pointer;
}

// ---------------------------------------------------------------------------
// Replace (algorithms/replace.rs) + capture
// ---------------------------------------------------------------------------

fn replacePass(a: Allocator, raw: []const DiffOp) Allocator.Error![]DiffOp {
    var out: Ops = .empty;
    var del: ?struct { usize, usize, usize } = null;
    var ins: ?struct { usize, usize, usize } = null;
    var eq: ?struct { usize, usize, usize } = null;

    const S = struct {
        fn flushEq(al: Allocator, o: *Ops, e: *?struct { usize, usize, usize }) Allocator.Error!void {
            if (e.*) |x| {
                try o.append(al, .{ .equal = .{ .old_index = x[0], .new_index = x[1], .len = x[2] } });
                e.* = null;
            }
        }
        fn flushDelIns(al: Allocator, o: *Ops, d: *?struct { usize, usize, usize }, i: *?struct { usize, usize, usize }) Allocator.Error!void {
            if (d.*) |x| {
                d.* = null;
                if (i.*) |y| {
                    i.* = null;
                    try o.append(al, .{ .replace = .{ .old_index = x[0], .old_len = x[1], .new_index = y[1], .new_len = y[2] } });
                } else {
                    try o.append(al, .{ .delete = .{ .old_index = x[0], .old_len = x[1], .new_index = x[2] } });
                }
            } else if (i.*) |y| {
                i.* = null;
                try o.append(al, .{ .insert = .{ .old_index = y[0], .new_index = y[1], .new_len = y[2] } });
            }
        }
    };

    for (raw) |op| {
        switch (op) {
            .equal => |e| {
                try S.flushDelIns(a, &out, &del, &ins);
                eq = if (eq) |x| .{ x[0], x[1], x[2] + e.len } else .{ e.old_index, e.new_index, e.len };
            },
            .delete => |d| {
                try S.flushEq(a, &out, &eq);
                del = if (del) |x| .{ x[0], x[1] + d.old_len, x[2] } else .{ d.old_index, d.old_len, d.new_index };
            },
            .insert => |i| {
                try S.flushEq(a, &out, &eq);
                ins = if (ins) |x| .{ x[0], x[1], i.new_len + x[2] } else .{ i.old_index, i.new_index, i.new_len };
            },
            .replace => |r| {
                try S.flushEq(a, &out, &eq);
                try out.append(a, .{ .replace = r });
            },
        }
    }
    try S.flushEq(a, &out, &eq);
    try S.flushDelIns(a, &out, &del, &ins);
    return out.toOwnedSlice(a);
}

/// `capture_diff_deadline(alg, old, .., new, .., None)`:
/// `Compact::new(Replace::new(Capture::new()))`.
pub fn captureDiff(a: Allocator, alg: Algorithm, old: Seq, new: Seq) Allocator.Error![]DiffOp {
    var raw: Ops = .empty;
    defer raw.deinit(a);
    const sink: Sink = .{ .a = a, .ops = &raw };
    const or_: Range = .{ .start = 0, .end = old.len };
    const nr: Range = .{ .start = 0, .end = new.len };
    switch (alg) {
        .myers => try myersDiff(a, sink, old, or_, new, nr),
        .patience => try patienceDiff(a, sink, old, or_, new, nr),
    }
    try cleanupDiffOps(a, old, new, &raw);
    return replacePass(a, raw.items);
}

/// Isolate change clusters by eliminating ranges with no changes
/// (`group_diff_ops`). Groups are allocated in `a`.
pub fn groupDiffOps(a: Allocator, ops_in: []const DiffOp, n: usize) Allocator.Error![][]DiffOp {
    if (ops_in.len == 0) return &.{};
    const ops = try a.dupe(DiffOp, ops_in);
    defer a.free(ops);
    var pending: Ops = .empty;
    var rv: std.ArrayList([]DiffOp) = .empty;

    if (ops[0] == .equal) {
        const e = &ops[0].equal;
        const offset = e.len -| n;
        e.old_index += offset;
        e.new_index += offset;
        e.len -= offset;
    }
    if (ops[ops.len - 1] == .equal) {
        const e = &ops[ops.len - 1].equal;
        e.len -= e.len -| n;
    }
    for (ops) |op| {
        if (op == .equal) {
            const e = op.equal;
            if (e.len > n * 2) {
                try pending.append(a, .{ .equal = .{ .old_index = e.old_index, .new_index = e.new_index, .len = n } });
                try rv.append(a, try pending.toOwnedSlice(a));
                const offset = e.len -| n;
                try pending.append(a, .{ .equal = .{ .old_index = e.old_index + offset, .new_index = e.new_index + offset, .len = e.len - offset } });
                continue;
            }
        }
        try pending.append(a, op);
    }
    if (!(pending.items.len == 0 or (pending.items.len == 1 and pending.items[0] == .equal))) {
        try rv.append(a, try pending.toOwnedSlice(a));
    } else pending.deinit(a);
    return rv.toOwnedSlice(a);
}

/// Similarity in `0..=1` (`get_diff_ratio`).
pub fn getDiffRatio(ops: []const DiffOp, old_len: usize, new_len: usize) f32 {
    var matches: usize = 0;
    for (ops) |op| if (op == .equal) {
        matches += op.equal.len;
    };
    const len = old_len + new_len;
    if (len == 0) return 1.0;
    return 2.0 * @as(f32, @floatFromInt(matches)) / @as(f32, @floatFromInt(len));
}

fn upperSeqRatio(l1: usize, l2: usize) f32 {
    const n = l1 + l2;
    if (n == 0) return 1.0;
    return 2.0 * @as(f32, @floatFromInt(@min(l1, l2))) / @as(f32, @floatFromInt(n));
}

// ---------------------------------------------------------------------------
// Tokenizers (text/abstraction.rs, `str` impl)
// ---------------------------------------------------------------------------

/// Lines keeping their terminators (`\n`, `\r\n`, or a lone `\r`).
pub fn tokenizeLines(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var last: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') {
                try out.append(a, s[last .. i + 2]);
                i += 1;
                last = i + 1;
            } else {
                try out.append(a, s[last .. i + 1]);
                last = i + 1;
            }
        } else if (c == '\n') {
            try out.append(a, s[last .. i + 1]);
            last = i + 1;
        }
    }
    if (last < s.len) try out.append(a, s[last..]);
    return out.toOwnedSlice(a);
}

fn isWs(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn charLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    return if (i + n <= s.len) n else 1;
}

fn charAt(s: []const u8, i: usize) u21 {
    const n = charLen(s, i);
    if (n == 1) return s[i];
    return std.unicode.utf8Decode(s[i .. i + n]) catch 0xFFFD;
}

/// Runs of whitespace / non-whitespace (`char::is_whitespace`).
pub fn tokenizeWords(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const ws = isWs(charAt(s, i));
        const start = i;
        i += charLen(s, i);
        while (i < s.len and isWs(charAt(s, i)) == ws) i += charLen(s, i);
        try out.append(a, s[start..i]);
    }
    return out.toOwnedSlice(a);
}

pub fn tokenizeChars(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = charLen(s, i);
        try out.append(a, s[i .. i + n]);
        i += n;
    }
    return out.toOwnedSlice(a);
}

/// Runs of newline / non-newline characters.
fn tokenizeLinesAndNewlines(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const nl = s[i] == '\r' or s[i] == '\n';
        const start = i;
        i += charLen(s, i);
        while (i < s.len and (s[i] == '\r' or s[i] == '\n') == nl) i += charLen(s, i);
        try out.append(a, s[start..i]);
    }
    return out.toOwnedSlice(a);
}

fn endsWithNewline(s: []const u8) bool {
    return s.len > 0 and (s[s.len - 1] == '\r' or s[s.len - 1] == '\n');
}

const Interner = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,

    fn ids(self: *Interner, a: Allocator, toks: []const []const u8) Allocator.Error![]u32 {
        const out = try a.alloc(u32, toks.len);
        for (toks, out) |t, *o| {
            const gop = try self.map.getOrPut(a, t);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(self.map.count() - 1);
            o.* = gop.value_ptr.*;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// TextDiff
// ---------------------------------------------------------------------------

pub const Change = struct {
    tag: ChangeTag,
    old_index: ?usize,
    new_index: ?usize,
    value: []const u8,
};

/// One emphasized-or-not segment of an inline change.
pub const InlineValue = struct { emphasized: bool, value: []const u8 };

pub const InlineChange = struct {
    tag: ChangeTag,
    old_index: ?usize,
    new_index: ?usize,
    values: []const InlineValue,

    pub fn missingNewline(self: InlineChange) bool {
        if (self.values.len == 0) return false;
        return !endsWithNewline(self.values[self.values.len - 1].value);
    }
};

pub const TextDiff = struct {
    arena: std.heap.ArenaAllocator,
    old: []const []const u8,
    new: []const []const u8,
    ops: []const DiffOp,
    newline_terminated: bool,
    algorithm: Algorithm,

    pub const Tokenizer = enum { lines, words, chars };

    /// `TextDiff::configure().algorithm(alg).diff_*(old, new)`; token slices
    /// borrow `old`/`new`, which must outlive the diff.
    pub fn init(gpa: Allocator, tok: Tokenizer, alg: Algorithm, old: []const u8, new: []const u8) Allocator.Error!TextDiff {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const ot, const nt = switch (tok) {
            .lines => .{ try tokenizeLines(a, old), try tokenizeLines(a, new) },
            .words => .{ try tokenizeWords(a, old), try tokenizeWords(a, new) },
            .chars => .{ try tokenizeChars(a, old), try tokenizeChars(a, new) },
        };
        var interner: Interner = .{};
        const oi = try interner.ids(a, ot);
        const ni = try interner.ids(a, nt);
        const ops = try captureDiff(a, alg, oi, ni);
        return .{ .arena = arena, .old = ot, .new = nt, .ops = ops, .newline_terminated = tok == .lines, .algorithm = alg };
    }

    pub fn fromLines(gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!TextDiff {
        return init(gpa, .lines, .myers, old, new);
    }

    pub fn fromWords(gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!TextDiff {
        return init(gpa, .words, .myers, old, new);
    }

    pub fn fromChars(gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!TextDiff {
        return init(gpa, .chars, .myers, old, new);
    }

    pub fn deinit(self: *TextDiff) void {
        self.arena.deinit();
    }

    pub fn ratio(self: *const TextDiff) f32 {
        return getDiffRatio(self.ops, self.old.len, self.new.len);
    }

    pub fn groupedOps(self: *TextDiff, n: usize) Allocator.Error![][]DiffOp {
        return groupDiffOps(self.arena.allocator(), self.ops, n);
    }

    /// The changes `op` expands to (`iter_changes`), appended to `out`.
    pub fn iterChanges(self: *const TextDiff, a: Allocator, op: DiffOp, out: *std.ArrayList(Change)) Allocator.Error!void {
        const orr = op.oldRange();
        const nr = op.newRange();
        switch (op) {
            .equal => for (0..orr.len()) |k| try out.append(a, .{ .tag = .equal, .old_index = orr.start + k, .new_index = nr.start + k, .value = self.old[orr.start + k] }),
            .delete => for (orr.start..orr.end) |i| try out.append(a, .{ .tag = .delete, .old_index = i, .new_index = null, .value = self.old[i] }),
            .insert => for (nr.start..nr.end) |i| try out.append(a, .{ .tag = .insert, .old_index = null, .new_index = i, .value = self.new[i] }),
            .replace => {
                for (orr.start..orr.end) |i| try out.append(a, .{ .tag = .delete, .old_index = i, .new_index = null, .value = self.old[i] });
                for (nr.start..nr.end) |i| try out.append(a, .{ .tag = .insert, .old_index = null, .new_index = i, .value = self.new[i] });
            },
        }
    }

    /// `iter_inline_changes` (the `inline` feature): for a `Replace` op whose
    /// sides are similar enough, word-level Patience diff marks the changed
    /// words as emphasized; everything else maps 1:1 from `iter_changes`.
    pub fn iterInlineChanges(self: *const TextDiff, a: Allocator, op: DiffOp, out: *std.ArrayList(InlineChange)) Allocator.Error!void {
        const MIN_RATIO: f32 = 0.5;
        if (op != .replace) return self.plainInline(a, op, out);
        const orr = op.oldRange();
        const nr = op.newRange();
        const old_slices = self.old[orr.start..orr.end];
        const new_slices = self.new[nr.start..nr.end];
        if (upperSeqRatio(old_slices.len, new_slices.len) < MIN_RATIO) return self.plainInline(a, op, out);

        var old_lookup = try MultiLookup.init(a, old_slices);
        var new_lookup = try MultiLookup.init(a, new_slices);
        var interner: Interner = .{};
        const oi = try interner.ids(a, old_lookup.words());
        const ni = try interner.ids(a, new_lookup.words());
        const ops = try captureDiff(a, .patience, oi, ni);
        if (getDiffRatio(ops, oi.len, ni.len) < MIN_RATIO) return self.plainInline(a, op, out);

        var old_values: std.ArrayList(std.ArrayList(InlineValue)) = .empty;
        var new_values: std.ArrayList(std.ArrayList(InlineValue)) = .empty;
        for (ops) |wop| {
            switch (wop) {
                .equal => |e| {
                    try pushSlices(a, &old_values, &old_lookup, e.old_index, e.len, false);
                    try pushSlices(a, &new_values, &new_lookup, e.new_index, e.len, false);
                },
                .delete => |d| try pushSlices(a, &old_values, &old_lookup, d.old_index, d.old_len, true),
                .insert => |i| try pushSlices(a, &new_values, &new_lookup, i.new_index, i.new_len, true),
                .replace => |r| {
                    try pushSlices(a, &old_values, &old_lookup, r.old_index, r.old_len, true);
                    try pushSlices(a, &new_values, &new_lookup, r.new_index, r.new_len, true);
                },
            }
        }
        var old_index = orr.start;
        for (old_values.items) |v| {
            try out.append(a, .{ .tag = .delete, .old_index = old_index, .new_index = null, .values = v.items });
            old_index += 1;
        }
        var new_index = nr.start;
        for (new_values.items) |v| {
            try out.append(a, .{ .tag = .insert, .old_index = null, .new_index = new_index, .values = v.items });
            new_index += 1;
        }
    }

    fn plainInline(self: *const TextDiff, a: Allocator, op: DiffOp, out: *std.ArrayList(InlineChange)) Allocator.Error!void {
        var changes: std.ArrayList(Change) = .empty;
        try self.iterChanges(a, op, &changes);
        for (changes.items) |c| {
            const vals = try a.alloc(InlineValue, 1);
            vals[0] = .{ .emphasized = false, .value = c.value };
            try out.append(a, .{ .tag = c.tag, .old_index = c.old_index, .new_index = c.new_index, .values = vals });
        }
    }
};

const MultiLookup = struct {
    strings: []const []const u8,
    seqs: std.ArrayList(struct { word: []const u8, str_idx: usize, offset: usize }) = .empty,
    word_list: std.ArrayList([]const u8) = .empty,

    fn init(a: Allocator, strings: []const []const u8) Allocator.Error!MultiLookup {
        var ml: MultiLookup = .{ .strings = strings };
        for (strings, 0..) |s, string_idx| {
            var offset: usize = 0;
            for (try tokenizeWords(a, s)) |w| {
                try ml.seqs.append(a, .{ .word = w, .str_idx = string_idx, .offset = offset });
                try ml.word_list.append(a, w);
                offset += w.len;
            }
        }
        return ml;
    }

    fn words(self: *MultiLookup) []const []const u8 {
        return self.word_list.items;
    }

    const Slice = struct { usize, []const u8 };

    fn originalSlices(self: *MultiLookup, a: Allocator, idx: usize, len: usize) Allocator.Error![]Slice {
        var last: ?struct { usize, usize, usize } = null;
        var rv: std.ArrayList(Slice) = .empty;
        for (0..len) |off| {
            const e = self.seqs.items[idx + off];
            if (last) |l| {
                if (l[0] == e.str_idx) {
                    last = .{ e.str_idx, l[1], l[2] + e.word.len };
                } else {
                    try rv.append(a, .{ l[0], self.strings[l[0]][l[1] .. l[1] + l[2]] });
                    last = .{ e.str_idx, e.offset, e.word.len };
                }
            } else {
                last = .{ e.str_idx, e.offset, e.word.len };
            }
        }
        if (last) |l| try rv.append(a, .{ l[0], self.strings[l[0]][l[1] .. l[1] + l[2]] });
        return rv.toOwnedSlice(a);
    }
};

fn pushSlices(a: Allocator, v: *std.ArrayList(std.ArrayList(InlineValue)), lookup: *MultiLookup, idx: usize, len: usize, emphasized: bool) Allocator.Error!void {
    for (try lookup.originalSlices(a, idx, len)) |sl| {
        const i = sl[0];
        while (v.items.len < i + 1) try v.append(a, .empty);
        // Newlines are never emphasized.
        if (emphasized) {
            for (try tokenizeLinesAndNewlines(a, sl[1])) |seg| {
                try v.items[i].append(a, .{ .emphasized = !endsWithNewline(seg), .value = seg });
            }
        } else {
            try v.items[i].append(a, .{ .emphasized = false, .value = sl[1] });
        }
    }
}

test "myers replace snapshot (similar test_mayers_replace)" {
    const a = std.testing.allocator;
    const old = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const new = [_]u32{ 0, 9, 2, 3, 4, 10, 6, 7, 8 };
    const ops = try captureDiff(a, .myers, &old, &new);
    defer a.free(ops);
    try std.testing.expectEqual(@as(usize, 5), ops.len);
    try std.testing.expect(ops[1] == .replace and ops[1].replace.old_index == 1);
    try std.testing.expect(ops[3] == .replace and ops[3].replace.old_index == 5);
}
