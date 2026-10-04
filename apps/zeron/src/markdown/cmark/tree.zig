//! Vec-based tree + item model — port of pulldown-cmark 0.12.2 `tree.rs`
//! and the `Item`/`ItemBody` types of `parse.rs`. Node index 0 is a dummy so
//! `nil` (0) can stand for `None`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ix = u32;
pub const nil: Ix = 0;

pub const CowIndex = u32;
pub const LinkIndex = u32;
pub const AlignmentIndex = u32;

pub const ItemBody = union(enum) {
    // Possible inline items, resolved in the second pass.
    maybe_emphasis: struct { count: usize, can_open: bool, can_close: bool },
    maybe_code: struct { count: usize, backslash: bool },
    maybe_html,
    maybe_link_open,
    /// whether the preceding section could be a reference
    maybe_link_close: bool,
    maybe_image,

    // Inline items after resolution.
    emphasis,
    strong,
    strikethrough,
    code: CowIndex,
    link: LinkIndex,
    image: LinkIndex,
    task_list_marker: bool,

    inline_html,
    owned_inline_html: CowIndex,
    synthesize_text: CowIndex,
    synthesize_char: u21,
    html,
    /// backslash_escaped
    text: bool,
    soft_break,
    /// true = is backslash
    hard_break: bool,

    root,

    // Block items.
    paragraph,
    rule,
    heading: u8,
    fenced_code_block: CowIndex,
    indent_code_block,
    html_block,
    block_quote,
    list: struct { tight: bool, ch: u8, start: u64 },
    list_item: usize,

    table: AlignmentIndex,
    table_head,
    table_row,
    table_cell,

    pub fn isMaybeInline(self: ItemBody) bool {
        return switch (self) {
            .maybe_emphasis, .maybe_code, .maybe_html, .maybe_link_open, .maybe_link_close, .maybe_image => true,
            else => false,
        };
    }

    pub fn isInline(self: ItemBody) bool {
        return switch (self) {
            .maybe_emphasis, .maybe_code, .maybe_html, .maybe_link_open, .maybe_link_close, .maybe_image, .emphasis, .strong, .strikethrough, .code, .link, .image, .task_list_marker, .inline_html, .owned_inline_html, .synthesize_text, .synthesize_char, .html, .text, .soft_break, .hard_break => true,
            else => false,
        };
    }

    pub fn isBlock(self: ItemBody) bool {
        return !self.isInline();
    }
};

pub const Item = struct {
    start: usize = 0,
    end: usize = 0,
    body: ItemBody = .root,
};

pub const Node = struct {
    child: Ix = nil,
    next: Ix = nil,
    item: Item = .{},
};

pub const Tree = struct {
    alloc: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    spine: std.ArrayList(Ix) = .empty,
    cur: Ix = nil,

    pub fn init(alloc: Allocator, cap: usize) Allocator.Error!Tree {
        var t: Tree = .{ .alloc = alloc };
        try t.nodes.ensureTotalCapacity(alloc, cap);
        t.nodes.appendAssumeCapacity(.{});
        return t;
    }

    pub inline fn n(self: *Tree, ix: Ix) *Node {
        return &self.nodes.items[ix];
    }

    pub inline fn get(self: *const Tree, ix: Ix) Node {
        return self.nodes.items[ix];
    }

    pub fn append(self: *Tree, item: Item) Allocator.Error!Ix {
        const ix = try self.createNode(item);
        if (self.cur != nil) {
            self.n(self.cur).next = ix;
        } else if (self.spine.items.len > 0) {
            self.n(self.spine.items[self.spine.items.len - 1]).child = ix;
        }
        self.cur = ix;
        return ix;
    }

    pub fn createNode(self: *Tree, item: Item) Allocator.Error!Ix {
        const ix: Ix = @intCast(self.nodes.items.len);
        try self.nodes.append(self.alloc, .{ .item = item });
        return ix;
    }

    pub fn push(self: *Tree) Allocator.Error!Ix {
        const cur_ix = self.cur;
        std.debug.assert(cur_ix != nil);
        try self.spine.append(self.alloc, cur_ix);
        self.cur = self.n(cur_ix).child;
        return cur_ix;
    }

    pub fn pop(self: *Tree) ?Ix {
        const ix = self.spine.pop() orelse return null;
        self.cur = ix;
        return ix;
    }

    pub fn removeNode(self: *Tree) ?Ix {
        const ix = self.spine.pop() orelse return null;
        self.cur = ix;
        _ = self.nodes.pop();
        self.n(ix).child = nil;
        return ix;
    }

    pub fn peekUp(self: *const Tree) Ix {
        return if (self.spine.items.len > 0) self.spine.items[self.spine.items.len - 1] else nil;
    }

    pub fn peekGrandparent(self: *const Tree) Ix {
        return if (self.spine.items.len >= 2) self.spine.items[self.spine.items.len - 2] else nil;
    }

    pub fn isEmpty(self: *const Tree) bool {
        return self.nodes.items.len <= 1;
    }

    pub fn spineLen(self: *const Tree) usize {
        return self.spine.items.len;
    }

    pub fn reset(self: *Tree) void {
        self.cur = if (self.isEmpty()) nil else 1;
        self.spine.clearRetainingCapacity();
    }

    pub fn nextSibling(self: *Tree, cur_ix: Ix) Ix {
        self.cur = self.n(cur_ix).next;
        return self.cur;
    }

    pub fn appendText(self: *Tree, start: usize, end: usize, backslash_escaped: bool) Allocator.Error!void {
        if (end > start) {
            if (self.cur != nil) {
                const c = self.n(self.cur);
                if (c.item.body == .text and c.item.end == start) {
                    c.item.end = end;
                    return;
                }
            }
            _ = try self.append(.{ .start = start, .end = end, .body = .{ .text = backslash_escaped } });
        }
    }

    pub fn isInTable(self: *const Tree) bool {
        var i = self.spine.items.len;
        while (i > 0) {
            i -= 1;
            const body = self.nodes.items[self.spine.items[i]].item.body;
            if (body == .table) return true;
            const might = body.isInline() or body == .table_head or body == .table_row or body == .table_cell;
            if (!might) return false;
        }
        return false;
    }
};
