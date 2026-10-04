//! zeron's block-level markdown model (port of `zeron_markdown::parser`'s
//! tree types). This is exactly what the transcript renderer consumes:
//! top-level blocks with source ranges, nested containers, and inline runs
//! carrying merged styles.
//!
//! Ownership: every `TopBlock` owns an arena holding its whole subtree and is
//! reference counted (the Rust model shares `Arc<TopBlock>` between the
//! canonical tree, the display tree and old paint snapshots). A `BlockTree`
//! owns one reference per entry; `deinit` releases them.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

pub const TaskMarker = struct {
    checked: bool,
    /// Byte range of `[ ]`, `[x]` or `[X]` in the original document.
    range: Range,

    pub fn eql(a: TaskMarker, b: TaskMarker) bool {
        return a.checked == b.checked and a.range.start == b.range.start and a.range.end == b.range.end;
    }
};

/// An image stays inline in the model; hosts opt in to visual media.
pub const InlineImage = struct {
    source: []const u8,
    alt: []const u8,
    title: []const u8,
    link: ?[]const u8,

    pub fn eql(a: InlineImage, b: InlineImage) bool {
        return std.mem.eql(u8, a.source, b.source) and std.mem.eql(u8, a.alt, b.alt) and
            std.mem.eql(u8, a.title, b.title) and optEql(a.link, b.link);
    }
};

pub fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Inline styling flags threaded through nested emphasis/links.
pub const InlineStyle = struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strikethrough: bool = false,
    /// Destination URL when inside a link.
    link: ?[]const u8 = null,
    /// Label to show instead of `text` for a file link whose text is the
    /// path itself. Never set by the parser (the UI's inline-code linker
    /// fills it).
    file_label: ?[]const u8 = null,
    image: ?InlineImage = null,
    task: ?TaskMarker = null,

    pub fn eql(a: InlineStyle, b: InlineStyle) bool {
        if (a.bold != b.bold or a.italic != b.italic or a.code != b.code or a.strikethrough != b.strikethrough) return false;
        if (!optEql(a.link, b.link) or !optEql(a.file_label, b.file_label)) return false;
        if ((a.image == null) != (b.image == null)) return false;
        if (a.image) |ia| if (!ia.eql(b.image.?)) return false;
        if ((a.task == null) != (b.task == null)) return false;
        if (a.task) |ta| if (!ta.eql(b.task.?)) return false;
        return true;
    }
};

/// One run of identically-styled inline text.
pub const InlineRun = struct {
    text: []const u8,
    style: InlineStyle = .{},

    pub fn eql(a: InlineRun, b: InlineRun) bool {
        return std.mem.eql(u8, a.text, b.text) and a.style.eql(b.style);
    }
};

/// GFM column alignment; unspecified renders as left.
pub const TableAlign = enum { left, center, right };

/// A markdown block. Containers nest.
pub const Block = union(enum) {
    paragraph: []const InlineRun,
    heading: struct { level: u8, runs: []const InlineRun },
    code_block: struct { language: ?[]const u8, code: []const u8 },
    block_quote: []const Block,
    list: struct { ordered_start: ?u64, items: []const []const Block },
    table: struct {
        header: []const []const InlineRun,
        rows: []const []const []const InlineRun,
        alignment: []const TableAlign,
    },
    rule,

    pub fn eql(a: Block, b: Block) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .paragraph => |r| runsEql(r, b.paragraph),
            .heading => |h| h.level == b.heading.level and runsEql(h.runs, b.heading.runs),
            .code_block => |c| optEql(c.language, b.code_block.language) and std.mem.eql(u8, c.code, b.code_block.code),
            .block_quote => |ch| blocksEql(ch, b.block_quote),
            .list => |l| blk: {
                const m = b.list;
                if ((l.ordered_start == null) != (m.ordered_start == null)) break :blk false;
                if (l.ordered_start != null and l.ordered_start.? != m.ordered_start.?) break :blk false;
                if (l.items.len != m.items.len) break :blk false;
                for (l.items, m.items) |x, y| if (!blocksEql(x, y)) break :blk false;
                break :blk true;
            },
            .table => |t| blk: {
                const u = b.table;
                if (!std.mem.eql(TableAlign, t.alignment, u.alignment)) break :blk false;
                if (!cellsEql(t.header, u.header)) break :blk false;
                if (t.rows.len != u.rows.len) break :blk false;
                for (t.rows, u.rows) |x, y| if (!cellsEql(x, y)) break :blk false;
                break :blk true;
            },
            .rule => true,
        };
    }
};

pub fn runsEql(a: []const InlineRun, b: []const InlineRun) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn cellsEql(a: []const []const InlineRun, b: []const []const InlineRun) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!runsEql(x, y)) return false;
    return true;
}

pub fn blocksEql(a: []const Block, b: []const Block) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// A top-level block plus its byte range in the source (the stable-boundary
/// anchor for incremental reparses). Immutable once built; shared by
/// reference count.
pub const TopBlock = struct {
    refs: std.atomic.Value(u32),
    arena: std.heap.ArenaAllocator,
    range: Range,
    block: Block,

    pub fn create(gpa: Allocator) Allocator.Error!*TopBlock {
        const tb = try gpa.create(TopBlock);
        tb.* = .{ .refs = .init(1), .arena = .init(gpa), .range = .{ .start = 0, .end = 0 }, .block = .rule };
        return tb;
    }

    pub fn retain(self: *TopBlock) *TopBlock {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *TopBlock) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self);
        }
    }

    pub fn eql(a: *const TopBlock, b: *const TopBlock) bool {
        return a.range.start == b.range.start and a.range.end == b.range.end and a.block.eql(b.block);
    }
};

/// The parse result: top-level blocks in document order.
pub const BlockTree = struct {
    blocks: []*TopBlock = &.{},

    pub fn deinit(self: *BlockTree, gpa: Allocator) void {
        for (self.blocks) |b| b.release();
        gpa.free(self.blocks);
        self.* = .{};
    }

    pub fn len(self: BlockTree) usize {
        return self.blocks.len;
    }

    pub fn isEmpty(self: BlockTree) bool {
        return self.blocks.len == 0;
    }

    /// A new handle sharing every block (`BlockTree::clone`).
    pub fn clone(self: BlockTree, gpa: Allocator) Allocator.Error!BlockTree {
        const out = try gpa.alloc(*TopBlock, self.blocks.len);
        for (self.blocks, out) |b, *o| o.* = b.retain();
        return .{ .blocks = out };
    }

    pub fn eql(a: BlockTree, b: BlockTree) bool {
        if (a.blocks.len != b.blocks.len) return false;
        for (a.blocks, b.blocks) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};
