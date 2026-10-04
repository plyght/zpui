//! Second (inline) pass and the offset event iterator — port of
//! pulldown-cmark 0.12.2 `parse.rs` (`Parser`, `OffsetIter`) for zeron's
//! option set. Events and byte ranges match `Parser::into_offset_iter()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sc = @import("scanners.zig");
const tree_mod = @import("tree.zig");
const fp_mod = @import("firstpass.zig");
const linklabel = @import("linklabel.zig");

const Tree = tree_mod.Tree;
const Item = tree_mod.Item;
const ItemBody = tree_mod.ItemBody;
const Ix = tree_mod.Ix;
const nil = tree_mod.nil;
const LineStart = sc.LineStart;
const scanContainers = fp_mod.scanContainers;

pub const Alignment = sc.Alignment;
pub const LinkType = fp_mod.LinkType;

pub const LinkTag = struct {
    link_type: LinkType,
    dest_url: []const u8,
    title: []const u8,
    id: []const u8,
};

pub const Tag = union(enum) {
    paragraph,
    heading: u8,
    block_quote,
    /// Fenced info string, or null for an indented block.
    code_block: ?[]const u8,
    html_block,
    /// Ordered start number, or null for a bullet list.
    list: ?u64,
    item,
    table: []const Alignment,
    table_head,
    table_row,
    table_cell,
    emphasis,
    strong,
    strikethrough,
    link: LinkTag,
    image: LinkTag,
};

pub const TagKind = std.meta.Tag(Tag);

pub const Event = union(enum) {
    start: Tag,
    end: TagKind,
    text: []const u8,
    code: []const u8,
    html: []const u8,
    inline_html: []const u8,
    soft_break,
    hard_break,
    rule,
    task_list_marker: bool,
};

pub const OffsetEvent = struct { event: Event, start: usize, end: usize };

const InlineEl = struct {
    start: Ix,
    count: usize,
    run_length: usize,
    c: u8,
    both: bool,
};

const InlineStack = struct {
    stack: std.ArrayList(InlineEl) = .empty,
    lower_bounds: [9]usize = @splat(0),

    const UNDERSCORE_NOT_BOTH = 0;
    const ASTERISK_NOT_BOTH = 1;
    const ASTERISK_BASE = 2;
    const TILDES = 5;
    const UNDERSCORE_BASE = 6;

    fn popAll(self: *InlineStack, tree: *Tree) void {
        for (self.stack.items) |el| {
            for (0..el.count) |i| tree.n(el.start + @as(Ix, @intCast(i))).item.body = .{ .text = false };
        }
        self.stack.clearRetainingCapacity();
        self.lower_bounds = @splat(0);
    }

    fn getLowerbound(self: *const InlineStack, c: u8, count: usize, both: bool) usize {
        if (c == '_') {
            const mod3_lower = self.lower_bounds[UNDERSCORE_BASE + count % 3];
            return if (both) mod3_lower else @min(mod3_lower, self.lower_bounds[UNDERSCORE_NOT_BOTH]);
        } else if (c == '*') {
            const mod3_lower = self.lower_bounds[ASTERISK_BASE + count % 3];
            return if (both) mod3_lower else @min(mod3_lower, self.lower_bounds[ASTERISK_NOT_BOTH]);
        } else {
            return self.lower_bounds[TILDES];
        }
    }

    fn setLowerbound(self: *InlineStack, c: u8, count: usize, both: bool, new_bound: usize) void {
        if (c == '_') {
            if (both) {
                self.lower_bounds[UNDERSCORE_BASE + count % 3] = new_bound;
            } else {
                self.lower_bounds[UNDERSCORE_NOT_BOTH] = new_bound;
            }
        } else if (c == '*') {
            self.lower_bounds[ASTERISK_BASE + count % 3] = new_bound;
            if (!both) self.lower_bounds[ASTERISK_NOT_BOTH] = new_bound;
        } else {
            self.lower_bounds[TILDES] = new_bound;
        }
    }

    fn truncate(self: *InlineStack, new_bound: usize) void {
        self.stack.shrinkRetainingCapacity(new_bound);
        for (&self.lower_bounds) |*lb| {
            if (lb.* > new_bound) lb.* = new_bound;
        }
    }

    fn findMatch(self: *InlineStack, tree: *Tree, c: u8, run_length: usize, both: bool) ?InlineEl {
        const lowerbound = @min(self.stack.items.len, self.getLowerbound(c, run_length, both));
        var found: ?usize = null;
        var j = self.stack.items.len;
        while (j > lowerbound) {
            j -= 1;
            const el = self.stack.items[j];
            if (c == '~' and run_length != el.run_length) continue;
            if (el.c == c and ((!both and !el.both) or (run_length + el.run_length) % 3 != 0 or run_length % 3 == 0)) {
                found = j;
                break;
            }
        }
        if (found) |matching_ix| {
            const matching_el = self.stack.items[matching_ix];
            for (self.stack.items[matching_ix + 1 ..]) |el| {
                for (0..el.count) |i| tree.n(el.start + @as(Ix, @intCast(i))).item.body = .{ .text = false };
            }
            self.truncate(matching_ix);
            return matching_el;
        }
        self.setLowerbound(c, run_length, both, self.stack.items.len);
        return null;
    }

    fn trimLowerBound(self: *InlineStack, ix: usize) void {
        self.lower_bounds[ix] = @min(self.lower_bounds[ix], self.stack.items.len);
    }

    fn push(self: *InlineStack, alloc: Allocator, el: InlineEl) Allocator.Error!void {
        if (el.c == '~') self.trimLowerBound(TILDES);
        try self.stack.append(alloc, el);
    }
};

const LinkStackTy = enum { link, image, disabled };
const LinkStackEl = struct { node: Ix, ty: LinkStackTy };

const LinkStack = struct {
    inner: std.ArrayList(LinkStackEl) = .empty,
    disabled_ix: usize = 0,

    fn push(self: *LinkStack, alloc: Allocator, el: LinkStackEl) Allocator.Error!void {
        try self.inner.append(alloc, el);
    }

    fn pop(self: *LinkStack) ?LinkStackEl {
        const el = self.inner.pop();
        self.disabled_ix = @min(self.disabled_ix, self.inner.items.len);
        return el;
    }

    fn clear(self: *LinkStack) void {
        self.inner.clearRetainingCapacity();
        self.disabled_ix = 0;
    }

    fn disableAllLinks(self: *LinkStack) void {
        for (self.inner.items[self.disabled_ix..]) |*el| {
            if (el.ty == .link) el.ty = .disabled;
        }
        self.disabled_ix = self.inner.items.len;
    }
};

const CodeDelims = struct {
    const Queue = struct { items: std.ArrayList(Ix) = .empty, head: usize = 0 };
    inner: std.AutoHashMapUnmanaged(usize, Queue) = .empty,
    seen_first: bool = false,

    fn insert(self: *CodeDelims, alloc: Allocator, count: usize, ix: Ix) Allocator.Error!void {
        if (self.seen_first) {
            const gop = try self.inner.getOrPut(alloc, count);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.items.append(alloc, ix);
        } else {
            self.seen_first = true;
        }
    }

    fn isPopulated(self: *const CodeDelims) bool {
        return self.inner.count() != 0;
    }

    fn find(self: *CodeDelims, open_ix: Ix, count: usize) ?Ix {
        const q = self.inner.getPtr(count) orelse return null;
        while (q.head < q.items.items.len) {
            const ix = q.items.items[q.head];
            q.head += 1;
            if (ix > open_ix) return ix;
        }
        return null;
    }

    fn clear(self: *CodeDelims) void {
        self.inner.clearRetainingCapacity();
        self.seen_first = false;
    }
};

const RefScan = union(enum) {
    link_label: struct { label: []const u8, end_ix: usize },
    collapsed: Ix,
    failed,
};

fn scanNodesToIx(tree: *const Tree, node_in: Ix, ix: usize) Ix {
    var node = node_in;
    while (node != nil) {
        if (tree.nodes.items[node].item.end <= ix) {
            node = tree.nodes.items[node].next;
        } else break;
    }
    return node;
}

fn containerLinebreak(ctx: ?*const anyopaque, bytes: []const u8) ?usize {
    const t: *const Tree = @ptrCast(@alignCast(ctx.?));
    var ls = LineStart.init(bytes);
    _ = scanContainers(t, &ls);
    return ls.bytesScanned();
}

fn scanLinkLabel(alloc: Allocator, tree: *const Tree, text: []const u8) Allocator.Error!?struct { usize, []const u8 } {
    if (text.len < 2 or text[0] != '[') return null;
    const r = (try linklabel.scanLinkLabelRest(alloc, text[1..], .{ .ctx = tree, .func = containerLinebreak }, tree.isInTable())) orelse return null;
    return .{ r[0] + 1, r[1] };
}

fn scanReference(alloc: Allocator, tree: *const Tree, text: []const u8, cur: Ix) Allocator.Error!RefScan {
    if (cur == nil) return .failed;
    const start = tree.nodes.items[cur].item.start;
    const tail = text[start..];
    if (std.mem.startsWith(u8, tail, "[]")) {
        const closing_node = tree.nodes.items[cur].next;
        return .{ .collapsed = tree.nodes.items[closing_node].next };
    }
    if (try scanLinkLabel(alloc, tree, text[start..])) |r| {
        return .{ .link_label = .{ .label = r[1], .end_ix = start + r[0] } };
    }
    return .failed;
}

pub const Parser = struct {
    alloc: Allocator,
    text: []const u8,
    tree: Tree,
    allocs: fp_mod.Allocations,
    html_scan_guard: sc.HtmlScanGuard = .{},
    link_ref_expansion_limit: usize,
    inline_stack: InlineStack = .{},
    link_stack: LinkStack = .{},
    code_delims: CodeDelims = .{},

    /// All allocations go to `alloc`; use an arena and drop it wholesale.
    pub fn init(alloc: Allocator, text: []const u8) Allocator.Error!Parser {
        const r = try fp_mod.FirstPass.run(alloc, text);
        var p: Parser = .{
            .alloc = alloc,
            .text = text,
            .tree = r[0],
            .allocs = r[1],
            .link_ref_expansion_limit = @max(text.len, 100_000),
        };
        p.tree.reset();
        return p;
    }

    fn fetchLinkTypeUrlTitle(self: *Parser, link_label: []const u8, link_type: LinkType) Allocator.Error!?struct { LinkType, []const u8, []const u8 } {
        if (self.link_ref_expansion_limit == 0) return null;
        const key = try linklabel.foldKey(self.alloc, link_label);
        const def = self.allocs.refdefs.get(key) orelse return null;
        const title = def.title orelse "";
        const url = def.dest;
        self.link_ref_expansion_limit -|= url.len + title.len;
        return .{ link_type, url, title };
    }

    fn handleInline(self: *Parser) Allocator.Error!void {
        try self.handleInlinePass1();
        try self.handleEmphasisAndHardBreak();
    }

    fn handleInlinePass1(self: *Parser) Allocator.Error!void {
        const tree = &self.tree;
        var cur = tree.cur;
        var prev: Ix = nil;

        const block_end = tree.n(tree.peekUp()).item.end;
        const block_text = self.text[0..block_end];

        while (cur != nil) {
            var cur_ix = cur;
            switch (tree.n(cur_ix).item.body) {
                .maybe_html => {
                    const next = tree.n(cur_ix).next;
                    const autolink = if (next != nil) sc.scanAutolink(block_text, tree.n(next).item.start) else null;
                    if (autolink) |al| {
                        const ix = al[0];
                        const node = scanNodesToIx(tree, next, ix);
                        const text_node = try tree.createNode(.{
                            .start = tree.n(cur_ix).item.start + 1,
                            .end = ix - 1,
                            .body = .{ .text = false },
                        });
                        const lt: LinkType = if (al[2] == .autolink) .autolink else .email;
                        const link_ix = try self.allocs.allocateLink(self.alloc, lt, al[1], "", "");
                        tree.n(cur_ix).item.body = .{ .link = link_ix };
                        tree.n(cur_ix).item.end = ix;
                        tree.n(cur_ix).next = node;
                        tree.n(cur_ix).child = text_node;
                        prev = cur;
                        cur = node;
                        if (cur != nil) tree.n(cur).item.start = @max(tree.n(cur).item.start, ix);
                        continue;
                    } else {
                        const inline_html = if (next != nil) try self.scanInlineHtml(block_text, tree.n(next).item.start) else null;
                        if (inline_html) |ih| {
                            const ix = ih[1];
                            const node = scanNodesToIx(tree, next, ix);
                            if (ih[0].len != 0) {
                                const cow = try self.allocs.allocateCow(self.alloc, ih[0]);
                                tree.n(cur_ix).item.body = .{ .owned_inline_html = cow };
                            } else {
                                tree.n(cur_ix).item.body = .inline_html;
                            }
                            tree.n(cur_ix).item.end = ix;
                            tree.n(cur_ix).next = node;
                            prev = cur;
                            cur = node;
                            if (cur != nil) tree.n(cur).item.start = @max(tree.n(cur).item.start, ix);
                            continue;
                        }
                    }
                    tree.n(cur_ix).item.body = .{ .text = false };
                },
                .maybe_code => |mc| {
                    var search_count = mc.count;
                    const preceded_by_backslash = mc.backslash;
                    if (preceded_by_backslash) {
                        search_count -= 1;
                        if (search_count == 0) {
                            tree.n(cur_ix).item.body = .{ .text = false };
                            prev = cur;
                            cur = tree.n(cur_ix).next;
                            continue;
                        }
                    }
                    if (self.code_delims.isPopulated()) {
                        if (self.code_delims.find(cur_ix, search_count)) |scan_ix| {
                            try self.makeCodeSpan(cur_ix, scan_ix, preceded_by_backslash);
                        } else {
                            tree.n(cur_ix).item.body = .{ .text = false };
                        }
                    } else {
                        var scan: Ix = if (search_count > 0) tree.n(cur_ix).next else nil;
                        while (scan != nil) {
                            const scan_ix = scan;
                            const body = tree.n(scan_ix).item.body;
                            if (body == .maybe_code) {
                                const delim_count = body.maybe_code.count;
                                if (search_count == delim_count) {
                                    try self.makeCodeSpan(cur_ix, scan_ix, preceded_by_backslash);
                                    self.code_delims.clear();
                                    break;
                                } else {
                                    try self.code_delims.insert(self.alloc, delim_count, scan_ix);
                                }
                            }
                            if (tree.n(scan_ix).item.body.isBlock()) {
                                scan = nil;
                                break;
                            }
                            scan = tree.n(scan_ix).next;
                        }
                        if (scan == nil) tree.n(cur_ix).item.body = .{ .text = false };
                    }
                },
                .maybe_link_open => {
                    tree.n(cur_ix).item.body = .{ .text = false };
                    try self.link_stack.push(self.alloc, .{ .node = cur_ix, .ty = .link });
                },
                .maybe_image => {
                    tree.n(cur_ix).item.body = .{ .text = false };
                    try self.link_stack.push(self.alloc, .{ .node = cur_ix, .ty = .image });
                },
                .maybe_link_close => |could_be_ref| {
                    tree.n(cur_ix).item.body = .{ .text = false };
                    if (self.link_stack.pop()) |tos| {
                        if (tos.ty == .disabled) continue;
                        const next = tree.n(cur_ix).next;
                        if (try self.scanInlineLink(block_text, tree.n(cur_ix).item.end, next)) |il| {
                            const next_ix = il[0];
                            const next_node = scanNodesToIx(tree, next, next_ix);
                            if (prev != nil) tree.n(prev).next = nil;
                            cur = tos.node;
                            cur_ix = tos.node;
                            const link_ix = try self.allocs.allocateLink(self.alloc, .inline_, il[1], il[2], "");
                            tree.n(cur_ix).item.body = if (tos.ty == .image) .{ .image = link_ix } else .{ .link = link_ix };
                            tree.n(cur_ix).child = tree.n(cur_ix).next;
                            tree.n(cur_ix).next = next_node;
                            tree.n(cur_ix).item.end = next_ix;
                            if (next_node != nil) tree.n(next_node).item.start = @max(tree.n(next_node).item.start, next_ix);
                            if (tos.ty == .link) self.link_stack.disableAllLinks();
                        } else {
                            const scan_result = try scanReference(self.alloc, tree, block_text, next);
                            var node_after_link: Ix = undefined;
                            var link_type: LinkType = undefined;
                            switch (scan_result) {
                                .link_label => |ll| {
                                    const reference_close_node = scanNodesToIx(tree, next, ll.end_ix - 1);
                                    if (reference_close_node == nil) continue;
                                    tree.n(reference_close_node).item.body = .{ .maybe_link_close = false };
                                    node_after_link = tree.n(reference_close_node).next;
                                    link_type = .reference;
                                },
                                .collapsed => |next_node| {
                                    if (!could_be_ref) continue;
                                    node_after_link = next_node;
                                    link_type = .collapsed;
                                },
                                .failed => {
                                    if (!could_be_ref) continue;
                                    node_after_link = next;
                                    link_type = .shortcut;
                                },
                            }

                            var label: ?struct { []const u8, usize } = null;
                            switch (scan_result) {
                                .link_label => |ll| label = .{ ll.label, ll.end_ix },
                                else => {
                                    const label_start = tree.n(tos.node).item.end - 1;
                                    const label_end = tree.n(cur_ix).item.end;
                                    if (try scanLinkLabel(self.alloc, tree, self.text[label_start..label_end])) |r| {
                                        if (label_start + r[0] == label_end) label = .{ r[1], label_start + r[0] };
                                    }
                                },
                            }
                            const id: []const u8 = if (label) |l| l[0] else "";
                            if (label) |l| {
                                if (try self.fetchLinkTypeUrlTitle(l[0], link_type)) |f| {
                                    const link_ix = try self.allocs.allocateLink(self.alloc, f[0], f[1], f[2], id);
                                    tree.n(tos.node).item.body = if (tos.ty == .image) .{ .image = link_ix } else .{ .link = link_ix };
                                    const label_node = tree.n(tos.node).next;
                                    tree.n(tos.node).next = node_after_link;
                                    if (label_node != cur) {
                                        tree.n(tos.node).child = label_node;
                                        if (prev != nil) tree.n(prev).next = nil;
                                    }
                                    tree.n(tos.node).item.end = l[1];
                                    cur = tos.node;
                                    cur_ix = tos.node;
                                    if (tos.ty == .link) self.link_stack.disableAllLinks();
                                }
                            }
                        }
                    }
                },
                else => {
                    if (cur != nil and tree.n(cur).item.body.isBlock()) self.link_stack.clear();
                },
            }
            prev = cur;
            cur = tree.n(cur_ix).next;
        }
        self.link_stack.clear();
        self.code_delims.clear();
    }

    fn handleEmphasisAndHardBreak(self: *Parser) Allocator.Error!void {
        const tree = &self.tree;
        var prev: Ix = nil;
        var cur = tree.cur;

        while (cur != nil) {
            var cur_ix = cur;
            switch (tree.n(cur_ix).item.body) {
                .maybe_emphasis => |me| {
                    var count = me.count;
                    const can_open = me.can_open;
                    const can_close = me.can_close;
                    const run_length = count;
                    const c = self.text[tree.n(cur_ix).item.start];
                    const both = can_open and can_close;
                    if (can_close) {
                        while (self.inline_stack.findMatch(tree, c, run_length, both)) |el| {
                            if (prev != nil) tree.n(prev).next = nil;
                            const match_count = @min(count, el.count);
                            var end: Ix = cur_ix - 1;
                            var start: Ix = el.start + @as(Ix, @intCast(el.count));
                            const lim: Ix = el.start + @as(Ix, @intCast(el.count - match_count));
                            while (start > lim) {
                                const inc: Ix = if (start > lim + 1) 2 else 1;
                                const ty: ItemBody = if (c == '~') .strikethrough else if (inc == 2) .strong else .emphasis;
                                const root = start - inc;
                                end = end + inc;
                                tree.n(root).item.body = ty;
                                tree.n(root).item.end = tree.n(end).item.end;
                                tree.n(root).child = start;
                                tree.n(root).next = nil;
                                start = root;
                            }
                            const prev_ix = lim;
                            prev = prev_ix;
                            cur = tree.n(cur_ix + @as(Ix, @intCast(match_count)) - 1).next;
                            tree.n(prev_ix).next = cur;

                            if (el.count > match_count) {
                                try self.inline_stack.push(self.alloc, .{
                                    .start = el.start,
                                    .count = el.count - match_count,
                                    .run_length = el.run_length,
                                    .c = el.c,
                                    .both = el.both,
                                });
                            }
                            count -= match_count;
                            if (count > 0) {
                                cur_ix = cur;
                            } else break;
                        }
                    }
                    if (count > 0) {
                        if (can_open) {
                            try self.inline_stack.push(self.alloc, .{ .start = cur_ix, .run_length = run_length, .count = count, .c = c, .both = both });
                        } else {
                            for (0..count) |i| tree.n(cur_ix + @as(Ix, @intCast(i))).item.body = .{ .text = false };
                        }
                        const prev_ix = cur_ix + @as(Ix, @intCast(count)) - 1;
                        prev = prev_ix;
                        cur = tree.n(prev_ix).next;
                    }
                },
                .hard_break => |is_backslash| {
                    if (is_backslash and tree.n(cur_ix).next == nil) tree.n(cur_ix).item.body = .{ .synthesize_char = '\\' };
                    prev = cur;
                    cur = tree.n(cur_ix).next;
                },
                else => {
                    prev = cur;
                    if (cur != nil and tree.n(cur).item.body.isBlock()) self.inline_stack.popAll(tree);
                    cur = tree.n(cur_ix).next;
                },
            }
        }
        self.inline_stack.popAll(tree);
    }

    fn scanSeparator(self: *Parser, underlying: []const u8, ix: *usize) void {
        ix.* += sc.scanWhile(underlying[ix.*..], sc.isAsciiWhitespaceNoNl);
        if (sc.scanEol(underlying[ix.*..])) |bl| {
            ix.* += bl;
            var line_start = LineStart.init(underlying[ix.*..]);
            _ = scanContainers(&self.tree, &line_start);
            ix.* += line_start.bytesScanned();
        }
        ix.* += sc.scanWhile(underlying[ix.*..], sc.isAsciiWhitespaceNoNl);
    }

    fn scanInlineLink(self: *Parser, underlying: []const u8, ix_in: usize, node: Ix) Allocator.Error!?struct { usize, []const u8, []const u8 } {
        var ix = ix_in;
        if (sc.scanCh(underlying[ix..], '(') == 0) return null;
        ix += 1;
        self.scanSeparator(underlying, &ix);
        const ld = sc.scanLinkDest(underlying, ix, fp_mod.LINK_MAX_NESTED_PARENS) orelse return null;
        const dest = try sc.unescape(self.alloc, ld[1], self.tree.isInTable());
        ix += ld[0];
        self.scanSeparator(underlying, &ix);
        var title: []const u8 = "";
        if (try self.scanLinkTitle(underlying, ix, node)) |t| {
            ix += t[0];
            self.scanSeparator(underlying, &ix);
            title = t[1];
        }
        if (sc.scanCh(underlying[ix..], ')') == 0) return null;
        ix += 1;
        return .{ ix, dest, title };
    }

    fn scanLinkTitle(self: *Parser, text: []const u8, start_ix: usize, node: Ix) Allocator.Error!?struct { usize, []const u8 } {
        const bytes = text;
        if (start_ix >= bytes.len) return null;
        const open = bytes[start_ix];
        if (!(open == '\'' or open == '"' or open == '(')) return null;
        const close: u8 = if (open == '(') ')' else open;

        var title: std.ArrayList(u8) = .empty;
        var mark = start_ix + 1;
        var i = start_ix + 1;
        while (i < bytes.len) {
            const c = bytes[i];
            if (c == close) {
                if (mark == 1) return .{ i - start_ix + 1, text[mark..i] };
                try title.appendSlice(self.alloc, text[mark..i]);
                return .{ i - start_ix + 1, title.items };
            }
            if (c == open) return null;
            if (c == '\n' or c == '\r') {
                const node_ix = scanNodesToIx(&self.tree, node, i + 1);
                if (node_ix != nil and self.tree.n(node_ix).item.start > i) {
                    try title.appendSlice(self.alloc, text[mark..i]);
                    try title.append(self.alloc, '\n');
                    i = self.tree.n(node_ix).item.start;
                    mark = i;
                    continue;
                }
            }
            if (c == '&') {
                const e = sc.scanEntity(bytes[i..]);
                if (e.value) |v| {
                    try title.appendSlice(self.alloc, text[mark..i]);
                    try title.appendSlice(self.alloc, v);
                    i += e.len;
                    mark = i;
                    continue;
                }
            }
            if (self.tree.isInTable() and c == '\\' and i + 2 < bytes.len and bytes[i + 1] == '\\' and bytes[i + 2] == '|') {
                try title.appendSlice(self.alloc, text[mark..i]);
                i += 2;
                mark = i;
            }
            if (c == '\\' and i + 1 < bytes.len and sc.isAsciiPunctuation(bytes[i + 1])) {
                try title.appendSlice(self.alloc, text[mark..i]);
                i += 1;
                mark = i;
            }
            i += 1;
        }
        return null;
    }

    fn makeCodeSpan(self: *Parser, open: Ix, close: Ix, preceding_backslash: bool) Allocator.Error!void {
        const tree = &self.tree;
        const bytes = self.text;
        const span_start = tree.n(open).item.end;
        const span_end = tree.n(close).item.start;
        var buf: ?std.ArrayList(u8) = null;

        var start_ix = span_start;
        var ix = span_start;
        while (ix < span_end) {
            const c = bytes[ix];
            if (c == '\r' or c == '\n') {
                if (buf == null) buf = .empty;
                try buf.?.appendSlice(self.alloc, self.text[start_ix..ix]);
                try buf.?.append(self.alloc, ' ');
                ix += 1;
                var line_start = LineStart.init(bytes[ix..]);
                _ = scanContainers(tree, &line_start);
                ix += line_start.bytesScanned();
                start_ix = ix;
            } else if (c == '\\' and ix + 1 < bytes.len and bytes[ix + 1] == '|' and tree.isInTable()) {
                if (buf == null) buf = .empty;
                try buf.?.appendSlice(self.alloc, self.text[start_ix..ix]);
                try buf.?.append(self.alloc, '|');
                ix += 2;
                start_ix = ix;
            } else {
                ix += 1;
            }
        }

        var s: []const u8 = undefined;
        if (buf) |*b| {
            try b.appendSlice(self.alloc, self.text[start_ix..span_end]);
            s = b.items;
        } else {
            s = self.text[span_start..span_end];
        }
        const opening = s.len > 0 and s[0] == ' ';
        const closing = s.len > 0 and s[s.len - 1] == ' ';
        var all_spaces = true;
        for (s) |b| {
            if (b != ' ') {
                all_spaces = false;
                break;
            }
        }

        var cow: []const u8 = undefined;
        if (!all_spaces and opening and closing) {
            if (buf != null) {
                cow = s[1 .. s.len - 1];
            } else {
                const lo = span_start + 1;
                const hi = @max(span_end - 1, lo);
                cow = self.text[lo..hi];
            }
        } else {
            cow = s;
        }

        const cow_ix = try self.allocs.allocateCow(self.alloc, cow);
        if (preceding_backslash) {
            tree.n(open).item.body = .{ .text = true };
            tree.n(open).item.end = tree.n(open).item.start + 1;
            tree.n(open).next = close;
            tree.n(close).item.body = .{ .code = cow_ix };
            tree.n(close).item.start = tree.n(open).item.start + 1;
        } else {
            tree.n(open).item.body = .{ .code = cow_ix };
            tree.n(open).item.end = tree.n(close).item.end;
            tree.n(open).next = tree.n(close).next;
        }
    }

    fn scanInlineHtml(self: *Parser, bytes: []const u8, ix: usize) Allocator.Error!?struct { []const u8, usize } {
        if (ix >= bytes.len) return null;
        const c = bytes[ix];
        if (c == '!') {
            const r = sc.scanInlineHtmlComment(bytes, ix + 1, &self.html_scan_guard) orelse return null;
            return .{ "", r };
        } else if (c == '?') {
            const r = sc.scanInlineHtmlProcessing(bytes, ix + 1, &self.html_scan_guard) orelse return null;
            return .{ "", r };
        } else {
            const r = (try sc.scanHtmlBlockInner(self.alloc, bytes[ix - 1 ..], fp_mod.containerSkipHandler(&self.tree))) orelse return null;
            return .{ r[0], r[1] + ix - 1 };
        }
    }

    fn bodyToTagEnd(body: ItemBody) TagKind {
        return switch (body) {
            .paragraph => .paragraph,
            .emphasis => .emphasis,
            .strong => .strong,
            .strikethrough => .strikethrough,
            .link => .link,
            .image => .image,
            .heading => .heading,
            .indent_code_block, .fenced_code_block => .code_block,
            .block_quote => .block_quote,
            .html_block => .html_block,
            .list => .list,
            .list_item => .item,
            .table_head => .table_head,
            .table_cell => .table_cell,
            .table_row => .table_row,
            .table => .table,
            else => unreachable,
        };
    }

    fn itemToEvent(self: *Parser, item: Item) Allocator.Error!Event {
        const tag: Tag = switch (item.body) {
            .text => return .{ .text = self.text[item.start..item.end] },
            .code => |ix| return .{ .code = self.allocs.cows.items[ix] },
            .synthesize_text => |ix| return .{ .text = self.allocs.cows.items[ix] },
            .synthesize_char => |cp| {
                var b: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &b) catch unreachable;
                return .{ .text = try self.alloc.dupe(u8, b[0..len]) };
            },
            .html_block => .html_block,
            .html => return .{ .html = self.text[item.start..item.end] },
            .inline_html => return .{ .inline_html = self.text[item.start..item.end] },
            .owned_inline_html => |ix| return .{ .inline_html = self.allocs.cows.items[ix] },
            .soft_break => return .soft_break,
            .hard_break => return .hard_break,
            .task_list_marker => |checked| return .{ .task_list_marker = checked },
            .rule => return .rule,
            .paragraph => .paragraph,
            .emphasis => .emphasis,
            .strong => .strong,
            .strikethrough => .strikethrough,
            .link => |ix| blk: {
                const l = self.allocs.links.items[ix];
                break :blk .{ .link = .{ .link_type = l.ty, .dest_url = l.url, .title = l.title, .id = l.id } };
            },
            .image => |ix| blk: {
                const l = self.allocs.links.items[ix];
                break :blk .{ .image = .{ .link_type = l.ty, .dest_url = l.url, .title = l.title, .id = l.id } };
            },
            .heading => |level| .{ .heading = level },
            .fenced_code_block => |ix| .{ .code_block = self.allocs.cows.items[ix] },
            .indent_code_block => .{ .code_block = null },
            .block_quote => .block_quote,
            .list => |l| if (l.ch == '.' or l.ch == ')') .{ .list = l.start } else .{ .list = null },
            .list_item => .item,
            .table_head => .table_head,
            .table_cell => .table_cell,
            .table_row => .table_row,
            .table => |ix| .{ .table = self.allocs.alignments.items[ix] },
            else => unreachable,
        };
        return .{ .start = tag };
    }

    /// Next `(event, range)`, exactly as `OffsetIter::next`.
    pub fn nextEvent(self: *Parser) Allocator.Error!?OffsetEvent {
        if (self.tree.cur == nil) {
            const ix = self.tree.pop() orelse return null;
            const item = self.tree.n(ix).item;
            const tag_end = bodyToTagEnd(item.body);
            _ = self.tree.nextSibling(ix);
            return .{ .event = .{ .end = tag_end }, .start = item.start, .end = item.end };
        }
        const cur_ix = self.tree.cur;
        if (self.tree.n(cur_ix).item.body.isMaybeInline()) try self.handleInline();
        const item = self.tree.n(cur_ix).item;
        const event = try self.itemToEvent(item);
        if (event == .start) {
            _ = try self.tree.push();
        } else {
            _ = self.tree.nextSibling(cur_ix);
        }
        return .{ .event = event, .start = item.start, .end = item.end };
    }
};

/// Collect every offset event of `text` (allocations live in `alloc`).
pub fn collectEvents(alloc: Allocator, text: []const u8) Allocator.Error![]OffsetEvent {
    var p = try Parser.init(alloc, text);
    var out: std.ArrayList(OffsetEvent) = .empty;
    while (try p.nextEvent()) |ev| try out.append(alloc, ev);
    return out.toOwnedSlice(alloc);
}
