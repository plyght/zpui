//! First pass: resolves block structure into a `Tree` with inline markup
//! candidates — a port of pulldown-cmark 0.12.2 `firstpass.rs` restricted to
//! zeron's option set (`ENABLE_TABLES | ENABLE_STRIKETHROUGH |
//! ENABLE_TASKLISTS`). Footnotes, math, metadata blocks, definition lists,
//! heading attributes, smart punctuation and GFM blockquote tags are off in
//! zeron, so their branches are omitted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sc = @import("scanners.zig");
const tree_mod = @import("tree.zig");
const linklabel = @import("linklabel.zig");
const unicode = @import("unicode.zig");

const Tree = tree_mod.Tree;
const Item = tree_mod.Item;
const ItemBody = tree_mod.ItemBody;
const Ix = tree_mod.Ix;
const nil = tree_mod.nil;
const LineStart = sc.LineStart;

pub const LINK_MAX_NESTED_PARENS: usize = 32;

pub const LinkType = enum { inline_, reference, collapsed, shortcut, autolink, email };

pub const LinkData = struct {
    ty: LinkType,
    url: []const u8,
    title: []const u8,
    id: []const u8,
};

pub const LinkDef = struct {
    dest: []const u8,
    title: ?[]const u8,
};

pub const Allocations = struct {
    refdefs: std.StringHashMapUnmanaged(LinkDef) = .empty,
    links: std.ArrayList(LinkData) = .empty,
    cows: std.ArrayList([]const u8) = .empty,
    alignments: std.ArrayList([]sc.Alignment) = .empty,

    pub fn allocateCow(self: *Allocations, alloc: Allocator, s: []const u8) Allocator.Error!tree_mod.CowIndex {
        const ix: tree_mod.CowIndex = @intCast(self.cows.items.len);
        try self.cows.append(alloc, s);
        return ix;
    }

    pub fn allocateLink(self: *Allocations, alloc: Allocator, ty: LinkType, url: []const u8, title: []const u8, id: []const u8) Allocator.Error!tree_mod.LinkIndex {
        const ix: tree_mod.LinkIndex = @intCast(self.links.items.len);
        try self.links.append(alloc, .{ .ty = ty, .url = url, .title = title, .id = id });
        return ix;
    }

    pub fn allocateAlignment(self: *Allocations, alloc: Allocator, a: []sc.Alignment) Allocator.Error!tree_mod.AlignmentIndex {
        const ix: tree_mod.AlignmentIndex = @intCast(self.alignments.items.len);
        try self.alignments.append(alloc, a);
        return ix;
    }
};

const TableParseMode = enum { scan, active, disabled };

const special_bytes: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for ("\n\r*_&\\[]<!`") |c| t[c] = true;
    t['|'] = true; // ENABLE_TABLES
    t['~'] = true; // ENABLE_STRIKETHROUGH
    break :blk t;
};

pub fn scanContainers(tree: *const Tree, line_start: *LineStart) usize {
    var i: usize = 0;
    for (tree.spine.items) |node_ix| {
        switch (tree.nodes.items[node_ix].item.body) {
            .block_quote => {
                const save = line_start.*;
                _ = line_start.scanSpace(3);
                if (!line_start.scanBlockquoteMarker()) {
                    line_start.* = save;
                    break;
                }
            },
            .list_item => |indent| {
                const save = line_start.*;
                if (!line_start.scanSpace(indent) and !line_start.isAtEol()) {
                    line_start.* = save;
                    break;
                }
            },
            else => {},
        }
        i += 1;
    }
    return i;
}

/// Newline handler adaptor for the HTML scanners: skips container prefixes.
pub fn containerSkipHandler(tree: *const Tree) sc.NewlineHandler {
    const S = struct {
        fn f(ctx: *const anyopaque, bytes: []const u8) usize {
            const t: *const Tree = @ptrCast(@alignCast(ctx));
            var ls = LineStart.init(bytes);
            _ = scanContainers(t, &ls);
            return ls.bytesScanned();
        }
    };
    return .{ .ctx = tree, .func = S.f };
}

pub const FirstPass = struct {
    alloc: Allocator,
    text: []const u8,
    tree: Tree,
    begin_list_item: ?usize = null,
    last_line_blank: bool = false,
    allocs: Allocations = .{},
    next_paragraph_task: ?Item = null,

    pub fn run(alloc: Allocator, text: []const u8) Allocator.Error!struct { Tree, Allocations } {
        const cap = @max(128, text.len / 32);
        var fp: FirstPass = .{ .alloc = alloc, .text = text, .tree = try Tree.init(alloc, cap) };
        var ix: usize = 0;
        while (ix < text.len) ix = try fp.parseBlock(ix);
        while (fp.tree.spineLen() > 0) fp.pop(ix);
        return .{ fp.tree, fp.allocs };
    }

    fn parseBlock(self: *FirstPass, start_ix_in: usize) Allocator.Error!usize {
        var start_ix = start_ix_in;
        const bytes = self.text;
        var line_start = LineStart.init(bytes[start_ix..]);

        const i = scanContainers(&self.tree, &line_start);
        const spine_len = self.tree.spineLen();
        var k = i;
        while (k < spine_len) : (k += 1) self.pop(start_ix);

        // Process new containers
        while (true) {
            const save = line_start;
            const outer_indent = line_start.scanSpaceUpto(4);
            if (outer_indent >= 4) {
                line_start = save;
                break;
            }
            const container_start = start_ix + line_start.bytesScanned();
            if (line_start.scanListMarkerWithIndent(outer_indent)) |m| {
                const after_marker_index = start_ix + line_start.bytesScanned();
                try self.continueList(container_start - outer_indent, m.ch, m.start);
                _ = try self.tree.append(.{
                    .start = container_start - outer_indent,
                    .end = after_marker_index,
                    .body = .{ .list_item = m.indent },
                });
                _ = try self.tree.push();
                if (sc.scanBlankLine(bytes[after_marker_index..])) |n| {
                    self.begin_list_item = after_marker_index + n;
                    return after_marker_index + n;
                }
                // ENABLE_TASKLISTS
                if (line_start.scanTaskListMarker()) |is_checked| {
                    const tlm: Item = .{
                        .start = after_marker_index,
                        .end = start_ix + line_start.bytesScanned(),
                        .body = .{ .task_list_marker = is_checked },
                    };
                    if (sc.scanBlankLine(bytes[tlm.end..])) |n| {
                        _ = try self.tree.append(tlm);
                        self.begin_list_item = tlm.end + n;
                        return tlm.end + n;
                    } else {
                        self.next_paragraph_task = tlm;
                    }
                }
            } else if (line_start.scanBlockquoteMarker()) {
                self.finishList(start_ix);
                _ = try self.tree.append(.{ .start = container_start, .end = 0, .body = .block_quote });
                _ = try self.tree.push();
            } else {
                line_start = save;
                break;
            }
        }

        const ix0 = start_ix + line_start.bytesScanned();

        if (sc.scanBlankLine(bytes[ix0..])) |n| {
            const up = self.tree.peekUp();
            if (up != nil) {
                const body = &self.tree.n(up).item.body;
                switch (body.*) {
                    .block_quote => {},
                    .list_item => |*indent| {
                        if (self.begin_list_item != null) {
                            self.last_line_blank = true;
                            indent.* = 0;
                        } else {
                            self.last_line_blank = true;
                        }
                    },
                    else => self.last_line_blank = true,
                }
            } else {
                self.last_line_blank = true;
            }
            return ix0 + n;
        }

        const remaining_space = line_start.remainingSpace();

        const indent = line_start.scanSpaceUpto(4);
        if (indent == 4) {
            self.finishList(start_ix);
            const ix = start_ix + line_start.bytesScanned();
            const rs = line_start.remainingSpace();
            return self.parseIndentedCodeBlock(ix, rs);
        }

        const ix = start_ix + line_start.bytesScanned();

        // HTML Blocks
        if (bytes[ix] == '<') {
            if (sc.getHtmlEndTag(bytes[ix + 1 ..])) |html_end_tag| {
                self.finishList(start_ix);
                return self.parseHtmlBlockType1To5(ix, html_end_tag, remaining_space, indent);
            }
            if (sc.startsHtmlBlockType6(bytes[ix + 1 ..])) {
                self.finishList(start_ix);
                return self.parseHtmlBlockType6Or7(ix, remaining_space, indent);
            }
            if ((try sc.scanHtmlType7(self.alloc, bytes[ix..])) != null) {
                self.finishList(start_ix);
                return self.parseHtmlBlockType6Or7(ix, remaining_space, indent);
            }
        }

        const hr = sc.scanHrule(bytes[ix..]);
        if (hr.ok) {
            self.finishList(start_ix);
            return self.parseHrule(hr.n, ix);
        }

        if (sc.scanAtxHeading(bytes[ix..])) |atx_size| {
            self.finishList(start_ix);
            return self.parseAtxHeading(ix, atx_size);
        }

        if (sc.scanCodeFence(bytes[ix..])) |cf| {
            self.finishList(start_ix);
            return self.parseFencedCodeBlock(ix, indent, cf[1], cf[0]);
        }

        // parse refdef
        while (try self.parseRefdefTotal(start_ix + line_start.bytesScanned())) |rd| {
            const gop = try self.allocs.refdefs.getOrPut(self.alloc, rd.label);
            if (!gop.found_existing) gop.value_ptr.* = rd.def;
            const container_start = start_ix + line_start.bytesScanned();
            var rix = container_start + rd.bytecount;
            if (sc.scanBlankLine(bytes[rix..])) |nl| {
                rix += nl;
                var lazy = LineStart.init(bytes[rix..]);
                const current_container = scanContainers(&self.tree, &lazy) == self.tree.spineLen();
                if (!lazy.scanSpace(4) and try self.scanParagraphInterrupt(bytes[rix + lazy.bytesScanned() ..], current_container)) {
                    self.finishList(start_ix);
                    return rix;
                } else {
                    line_start = lazy;
                    line_start.scanAllSpace();
                    start_ix = rix;
                }
            } else {
                self.finishList(start_ix);
                return rix;
            }
        }

        return self.parseParagraph(start_ix + line_start.bytesScanned());
    }

    fn parseTable(self: *FirstPass, table_cols: usize, head_start: usize, body_start: usize) Allocator.Error!?usize {
        var missing_empty_cells: usize = 0;
        const head = (try self.parseTableRowInner(head_start, table_cols, &missing_empty_cells)) orelse return null;
        self.tree.n(head[1]).item.body = .table_head;
        var ix = body_start;
        while (try self.parseTableRow(ix, table_cols, &missing_empty_cells)) |r| ix = r[0];
        self.pop(ix);
        return ix;
    }

    fn parseTableRowInner(self: *FirstPass, ix_in: usize, row_cells: usize, missing_empty_cells: *usize) Allocator.Error!?struct { usize, Ix } {
        const MAX_AUTOCOMPLETED_CELLS: usize = 1 << 18;
        var ix = ix_in;
        const bytes = self.text;
        var cells: usize = 0;
        var final_cell_ix: Ix = nil;

        const old_cur = self.tree.cur;
        const row_ix = try self.tree.append(.{ .start = ix, .end = 0, .body = .table_row });
        _ = try self.tree.push();

        while (true) {
            ix += sc.scanCh(bytes[ix..], '|');
            const start_ix = ix;
            ix += sc.scanWhitespaceNoNl(bytes[ix..]);
            if (sc.scanEol(bytes[ix..])) |eol_bytes| {
                ix += eol_bytes;
                break;
            }
            const cell_ix = try self.tree.append(.{ .start = start_ix, .end = ix, .body = .table_cell });
            _ = try self.tree.push();
            const r = try self.parseLine(ix, .active);
            self.tree.n(cell_ix).item.end = r[0];
            _ = self.tree.pop();
            ix = r[0];
            cells += 1;
            if (cells == row_cells) final_cell_ix = cell_ix;
        }

        if (old_cur != nil and cells == 0) {
            self.pop(ix);
            self.tree.n(old_cur).next = nil;
            return null;
        }

        var c = cells;
        while (c < row_cells) : (c += 1) {
            if (missing_empty_cells.* >= MAX_AUTOCOMPLETED_CELLS) return null;
            missing_empty_cells.* += 1;
            _ = try self.tree.append(.{ .start = ix, .end = ix, .body = .table_cell });
        }

        if (final_cell_ix != nil) self.tree.n(final_cell_ix).next = nil;

        self.pop(ix);
        return .{ ix, row_ix };
    }

    fn parseTableRow(self: *FirstPass, ix_in: usize, row_cells: usize, missing_empty_cells: *usize) Allocator.Error!?struct { usize, Ix } {
        var ix = ix_in;
        const bytes = self.text;
        var line_start = LineStart.init(bytes[ix..]);
        const current_container = scanContainers(&self.tree, &line_start) == self.tree.spineLen();
        if (!current_container) return null;
        line_start.scanAllSpace();
        ix += line_start.bytesScanned();
        if (scanParagraphInterruptNoTable(bytes[ix..], current_container, &self.tree)) return null;
        return self.parseTableRowInner(ix, row_cells, missing_empty_cells);
    }

    fn parseParagraph(self: *FirstPass, start_ix: usize) Allocator.Error!usize {
        self.finishList(start_ix);
        const node_ix = try self.tree.append(.{ .start = start_ix, .end = 0, .body = .paragraph });
        _ = try self.tree.push();

        if (self.next_paragraph_task) |item| {
            _ = try self.tree.append(item);
            self.next_paragraph_task = null;
        }

        const bytes = self.text;
        var ix = start_ix;
        while (true) {
            const scan_mode: TableParseMode = if (ix == start_ix) .scan else .disabled;
            const r = try self.parseLine(ix, scan_mode);
            const next_ix = r[0];
            const brk = r[1];

            if (brk) |b| if (b.body == .table) {
                const alignment_ix = b.body.table;
                const table_cols = self.allocs.alignments.items[alignment_ix].len;
                self.tree.n(node_ix).item.body = .{ .table = alignment_ix };
                self.tree.n(node_ix).child = nil;
                _ = self.tree.pop();
                _ = try self.tree.push();
                if (try self.parseTable(table_cols, ix, next_ix)) |end| return end;
            };

            ix = next_ix;
            var line_start = LineStart.init(bytes[ix..]);
            const current_container = scanContainers(&self.tree, &line_start) == self.tree.spineLen();
            var trailing_backslash_pos: ?usize = null;
            if (brk) |b| {
                if (b.body == .hard_break and b.body.hard_break and bytes[b.start] == '\\') trailing_backslash_pos = b.start;
            }
            if (!line_start.scanSpace(4)) {
                const ix_new = ix + line_start.bytesScanned();
                if (current_container) {
                    if (self.parseSetextHeading(ix_new, node_ix, trailing_backslash_pos != null)) |ix_setext| {
                        if (trailing_backslash_pos) |pos| try self.tree.appendText(pos, pos + 1, false);
                        self.pop(ix_setext);
                        return ix_setext;
                    }
                }
                if (try self.scanParagraphInterrupt(bytes[ix_new..], current_container)) {
                    if (trailing_backslash_pos) |pos| try self.tree.appendText(pos, pos + 1, false);
                    break;
                }
            }
            line_start.scanAllSpace();
            if (line_start.isAtEol()) {
                if (trailing_backslash_pos) |pos| try self.tree.appendText(pos, pos + 1, false);
                break;
            }
            ix = next_ix + line_start.bytesScanned();
            if (brk) |item| _ = try self.tree.append(item);
        }

        self.pop(ix);
        return ix;
    }

    fn parseSetextHeading(self: *FirstPass, ix: usize, node_ix: Ix, has_trailing_content: bool) ?usize {
        const bytes = self.text;
        const sh = sc.scanSetextHeading(bytes[ix..]) orelse return null;
        const cur_ix = self.tree.cur;
        if (cur_ix != nil) {
            const parent_ix = self.tree.peekUp();
            const header_start = self.tree.n(parent_ix).item.start;
            const header_end = self.tree.n(cur_ix).item.end;
            const content_end = header_end;
            const new_end = if (has_trailing_content) content_end else blk: {
                const last_line_start = header_start;
                const trailing_ws = sc.scanRevWhile(bytes[last_line_start..content_end], sc.isAsciiWhitespaceNoNl);
                break :blk content_end - trailing_ws;
            };
            self.tree.n(cur_ix).item.end = new_end;
        }
        self.tree.n(node_ix).item.body = .{ .heading = sh[1] };
        return ix + sh[0];
    }

    /// Parse a line of input, appending text and items to tree.
    /// Returns: index after line and an item representing the break.
    fn parseLine(self: *FirstPass, start: usize, mode: TableParseMode) Allocator.Error!struct { usize, ?Item } {
        const bytes = self.text;
        const bytes_len = bytes.len;
        var pipes: usize = 0;
        var last_pipe_ix = start;
        var begin_text = start;
        var backslash_escaped = false;

        var final_ix: usize = bytes_len;
        var brk: ?Item = null;

        var ix = start;
        outer: while (ix < bytes_len) {
            const b = bytes[ix];
            if (special_bytes[b]) {
                var skip: usize = 0;
                switch (b) {
                    '\n', '\r' => {
                        if (mode == .active) {
                            final_ix = ix;
                            break :outer;
                        }
                        var i = ix;
                        const eol_bytes = sc.scanEol(bytes[ix..]).?;
                        const end_ix = ix + eol_bytes;
                        const trailing_backslashes = sc.scanRevCh(bytes[0..ix], '\\');
                        if (trailing_backslashes % 2 == 1 and end_ix < bytes_len) {
                            i -= 1;
                            try self.tree.appendText(begin_text, i, backslash_escaped);
                            backslash_escaped = false;
                            final_ix = end_ix;
                            brk = .{ .start = i, .end = end_ix, .body = .{ .hard_break = true } };
                            break :outer;
                        }
                        if (mode == .scan and pipes > 0) {
                            const next_line_ix = ix + eol_bytes;
                            var line_start = LineStart.init(bytes[next_line_ix..]);
                            if (scanContainers(&self.tree, &line_start) == self.tree.spineLen()) {
                                const table_head_ix = next_line_ix + line_start.bytesScanned();
                                const th = try sc.scanTableHead(self.alloc, bytes[table_head_ix..]);
                                if (th[0] > 0) {
                                    const header_count = countHeaderCols(bytes, pipes, start, last_pipe_ix);
                                    if (th[1].len == header_count) {
                                        const alignment_ix = try self.allocs.allocateAlignment(self.alloc, th[1]);
                                        const end2 = table_head_ix + th[0];
                                        final_ix = end2;
                                        brk = .{ .start = i, .end = end2, .body = .{ .table = alignment_ix } };
                                        break :outer;
                                    }
                                }
                            }
                        }
                        const trailing_whitespace = sc.scanRevWhile(bytes[0..ix], sc.isAsciiWhitespaceNoNl);
                        if (trailing_whitespace >= 2) {
                            i -= trailing_whitespace;
                            try self.tree.appendText(begin_text, i, backslash_escaped);
                            backslash_escaped = false;
                            final_ix = end_ix;
                            brk = .{ .start = i, .end = end_ix, .body = .{ .hard_break = false } };
                            break :outer;
                        }
                        try self.tree.appendText(begin_text, ix - trailing_whitespace, backslash_escaped);
                        backslash_escaped = false;
                        final_ix = end_ix;
                        brk = .{ .start = i, .end = end_ix, .body = .soft_break };
                        break :outer;
                    },
                    '\\' => {
                        if (ix + 1 < bytes_len and sc.isAsciiPunctuation(bytes[ix + 1])) {
                            try self.tree.appendText(begin_text, ix, backslash_escaped);
                            if (bytes[ix + 1] == '`') {
                                const count = 1 + sc.scanChRepeat(bytes[ix + 2 ..], '`');
                                _ = try self.tree.append(.{
                                    .start = ix + 1,
                                    .end = ix + count + 1,
                                    .body = .{ .maybe_code = .{ .count = count, .backslash = true } },
                                });
                                begin_text = ix + 1 + count;
                                backslash_escaped = false;
                                skip = count;
                            } else if (bytes[ix + 1] == '|' and mode == .active) {
                                begin_text = ix + 1;
                                backslash_escaped = false;
                                skip = 1;
                            } else if (ix + 2 < bytes_len and bytes[ix + 1] == '\\' and bytes[ix + 2] == '|' and mode == .active) {
                                begin_text = ix + 2;
                                backslash_escaped = true;
                                skip = 2;
                            } else {
                                begin_text = ix + 1;
                                backslash_escaped = true;
                                skip = 1;
                            }
                        }
                    },
                    '*', '_', '~' => {
                        const c = b;
                        const string_suffix = self.text[ix..];
                        const count = 1 + sc.scanChRepeat(string_suffix[1..], c);
                        const can_open = delimRunCanOpen(self.text[start..], string_suffix, count, ix - start, mode);
                        const can_close = delimRunCanClose(self.text[start..], string_suffix, count, ix - start, mode);
                        const is_valid_seq = c != '~' or count <= 2;
                        if ((can_open or can_close) and is_valid_seq) {
                            try self.tree.appendText(begin_text, ix, backslash_escaped);
                            backslash_escaped = false;
                            for (0..count) |j| {
                                _ = try self.tree.append(.{
                                    .start = ix + j,
                                    .end = ix + j + 1,
                                    .body = .{ .maybe_emphasis = .{ .count = count - j, .can_open = can_open, .can_close = can_close } },
                                });
                            }
                            begin_text = ix + count;
                        }
                        skip = count - 1;
                    },
                    '`' => {
                        try self.tree.appendText(begin_text, ix, backslash_escaped);
                        backslash_escaped = false;
                        const count = 1 + sc.scanChRepeat(bytes[ix + 1 ..], '`');
                        _ = try self.tree.append(.{
                            .start = ix,
                            .end = ix + count,
                            .body = .{ .maybe_code = .{ .count = count, .backslash = false } },
                        });
                        begin_text = ix + count;
                        skip = count - 1;
                    },
                    '<' => {
                        if (!(ix + 1 < bytes_len and bytes[ix + 1] == '\\')) {
                            try self.tree.appendText(begin_text, ix, backslash_escaped);
                            backslash_escaped = false;
                            _ = try self.tree.append(.{ .start = ix, .end = ix + 1, .body = .maybe_html });
                            begin_text = ix + 1;
                        }
                    },
                    '!' => {
                        if (ix + 1 < bytes_len and bytes[ix + 1] == '[') {
                            try self.tree.appendText(begin_text, ix, backslash_escaped);
                            backslash_escaped = false;
                            _ = try self.tree.append(.{ .start = ix, .end = ix + 2, .body = .maybe_image });
                            begin_text = ix + 2;
                            skip = 1;
                        }
                    },
                    '[' => {
                        try self.tree.appendText(begin_text, ix, backslash_escaped);
                        backslash_escaped = false;
                        _ = try self.tree.append(.{ .start = ix, .end = ix + 1, .body = .maybe_link_open });
                        begin_text = ix + 1;
                    },
                    ']' => {
                        try self.tree.appendText(begin_text, ix, backslash_escaped);
                        backslash_escaped = false;
                        _ = try self.tree.append(.{ .start = ix, .end = ix + 1, .body = .{ .maybe_link_close = true } });
                        begin_text = ix + 1;
                    },
                    '&' => {
                        const e = sc.scanEntity(bytes[ix..]);
                        if (e.value) |v| {
                            try self.tree.appendText(begin_text, ix, backslash_escaped);
                            backslash_escaped = false;
                            const owned = try self.alloc.dupe(u8, v);
                            const cow = try self.allocs.allocateCow(self.alloc, owned);
                            _ = try self.tree.append(.{ .start = ix, .end = ix + e.len, .body = .{ .synthesize_text = cow } });
                            begin_text = ix + e.len;
                            skip = e.len - 1;
                        }
                    },
                    '|' => {
                        if (ix != 0 and bytes[ix - 1] == '\\') {} else if (mode == .active) {
                            final_ix = ix;
                            break :outer;
                        } else {
                            last_pipe_ix = ix;
                            pipes += 1;
                        }
                    },
                    else => {},
                }
                ix += skip;
            }
            ix += 1;
        }

        if (brk == null) {
            const trailing_whitespace = sc.scanRevWhile(bytes[begin_text..final_ix], sc.isAsciiWhitespaceNoNl);
            try self.tree.appendText(begin_text, final_ix - trailing_whitespace, backslash_escaped);
        }
        return .{ final_ix, brk };
    }

    fn parseHtmlBlockType1To5(self: *FirstPass, start_ix: usize, html_end_tag: []const u8, remaining_space_in: usize, indent_in: usize) Allocator.Error!usize {
        var remaining_space = remaining_space_in;
        var indent = indent_in;
        _ = try self.tree.append(.{ .start = start_ix, .end = 0, .body = .html_block });
        _ = try self.tree.push();
        const bytes = self.text;
        var ix = start_ix;
        var end_ix: usize = undefined;
        while (true) {
            const line_start_ix = ix;
            ix += sc.scanNextline(bytes[ix..]);
            try self.appendHtmlLine(@max(remaining_space, indent), line_start_ix, ix);
            var line_start = LineStart.init(bytes[ix..]);
            const n_containers = scanContainers(&self.tree, &line_start);
            if (n_containers < self.tree.spineLen()) {
                end_ix = ix;
                break;
            }
            if (std.mem.indexOf(u8, self.text[line_start_ix..ix], html_end_tag) != null) {
                end_ix = ix;
                break;
            }
            const next_line_ix = ix + line_start.bytesScanned();
            if (next_line_ix == self.text.len) {
                end_ix = next_line_ix;
                break;
            }
            ix = next_line_ix;
            remaining_space = line_start.remainingSpace();
            indent = 0;
        }
        self.pop(end_ix);
        return ix;
    }

    fn parseHtmlBlockType6Or7(self: *FirstPass, start_ix: usize, remaining_space_in: usize, indent_in: usize) Allocator.Error!usize {
        var remaining_space = remaining_space_in;
        var indent = indent_in;
        _ = try self.tree.append(.{ .start = start_ix, .end = 0, .body = .html_block });
        _ = try self.tree.push();
        const bytes = self.text;
        var ix = start_ix;
        var end_ix: usize = undefined;
        while (true) {
            const line_start_ix = ix;
            ix += sc.scanNextline(bytes[ix..]);
            try self.appendHtmlLine(@max(remaining_space, indent), line_start_ix, ix);
            var line_start = LineStart.init(bytes[ix..]);
            const n_containers = scanContainers(&self.tree, &line_start);
            if (n_containers < self.tree.spineLen() or line_start.isAtEol()) {
                end_ix = ix;
                break;
            }
            const next_line_ix = ix + line_start.bytesScanned();
            if (next_line_ix == self.text.len or sc.scanBlankLine(bytes[next_line_ix..]) != null) {
                end_ix = next_line_ix;
                break;
            }
            ix = next_line_ix;
            remaining_space = line_start.remainingSpace();
            indent = 0;
        }
        self.pop(end_ix);
        return ix;
    }

    fn parseIndentedCodeBlock(self: *FirstPass, start_ix: usize, remaining_space_in: usize) Allocator.Error!usize {
        var remaining_space = remaining_space_in;
        _ = try self.tree.append(.{ .start = start_ix, .end = 0, .body = .indent_code_block });
        _ = try self.tree.push();
        const bytes = self.text;
        var last_nonblank_child: Ix = nil;
        var last_nonblank_ix: usize = 0;
        var end_ix: usize = 0;
        self.last_line_blank = false;

        var ix = start_ix;
        while (true) {
            const line_start_ix = ix;
            ix += sc.scanNextline(bytes[ix..]);
            try self.appendCodeText(remaining_space, line_start_ix, ix);
            if (!self.last_line_blank) {
                last_nonblank_child = self.tree.cur;
                last_nonblank_ix = ix;
                end_ix = ix;
            }
            var line_start = LineStart.init(bytes[ix..]);
            const n_containers = scanContainers(&self.tree, &line_start);
            if (n_containers < self.tree.spineLen() or !(line_start.scanSpace(4) or line_start.isAtEol())) break;
            const next_line_ix = ix + line_start.bytesScanned();
            if (next_line_ix == self.text.len) break;
            ix = next_line_ix;
            remaining_space = line_start.remainingSpace();
            self.last_line_blank = sc.scanBlankLine(bytes[ix..]) != null;
        }

        if (last_nonblank_child != nil) {
            self.tree.n(last_nonblank_child).next = nil;
            self.tree.n(last_nonblank_child).item.end = last_nonblank_ix;
        }
        self.pop(end_ix);
        return ix;
    }

    fn parseFencedCodeBlock(self: *FirstPass, start_ix: usize, indent: usize, fence_ch: u8, n_fence_char: usize) Allocator.Error!usize {
        const bytes = self.text;
        var info_start = start_ix + n_fence_char;
        info_start += sc.scanWhitespaceNoNl(bytes[info_start..]);
        var ix = info_start + sc.scanNextline(bytes[info_start..]);
        const info_end = ix - sc.scanRevWhile(bytes[info_start..ix], sc.isAsciiWhitespace);
        const info_string = try sc.unescape(self.alloc, self.text[info_start..info_end], self.tree.isInTable());
        const cow = try self.allocs.allocateCow(self.alloc, info_string);
        _ = try self.tree.append(.{ .start = start_ix, .end = 0, .body = .{ .fenced_code_block = cow } });
        _ = try self.tree.push();
        while (true) {
            var line_start = LineStart.init(bytes[ix..]);
            const n_containers = scanContainers(&self.tree, &line_start);
            if (n_containers < self.tree.spineLen()) {
                self.pop(ix);
                return ix;
            }
            _ = line_start.scanSpace(indent);
            var close_line_start = line_start;
            if (!close_line_start.scanSpace(4 - indent)) {
                const close_ix = ix + close_line_start.bytesScanned();
                if (sc.scanClosingCodeFence(bytes[close_ix..], fence_ch, n_fence_char)) |n| {
                    ix = close_ix + n;
                    self.pop(ix);
                    return ix + (sc.scanBlankLine(bytes[ix..]) orelse 0);
                }
            }
            const remaining_space = line_start.remainingSpace();
            ix += line_start.bytesScanned();
            const next_ix = ix + sc.scanNextline(bytes[ix..]);
            try self.appendCodeText(remaining_space, ix, next_ix);
            ix = next_ix;
        }
    }

    fn appendCodeText(self: *FirstPass, remaining_space: usize, start: usize, end: usize) Allocator.Error!void {
        if (remaining_space > 0) {
            const cow = try self.allocs.allocateCow(self.alloc, "   "[0..remaining_space]);
            _ = try self.tree.append(.{ .start = start, .end = start, .body = .{ .synthesize_text = cow } });
        }
        if (end >= 2 and self.text[end - 2] == '\r') {
            try self.tree.appendText(start, end - 2, false);
            try self.tree.appendText(end - 1, end, false);
        } else {
            try self.tree.appendText(start, end, false);
        }
    }

    fn appendHtmlLine(self: *FirstPass, remaining_space: usize, start: usize, end: usize) Allocator.Error!void {
        if (remaining_space > 0) {
            const cow = try self.allocs.allocateCow(self.alloc, "   "[0..remaining_space]);
            _ = try self.tree.append(.{ .start = start, .end = start, .body = .{ .synthesize_text = cow } });
        }
        if (end >= 2 and self.text[end - 2] == '\r') {
            _ = try self.tree.append(.{ .start = start, .end = end - 2, .body = .html });
            _ = try self.tree.append(.{ .start = end - 1, .end = end, .body = .html });
        } else {
            _ = try self.tree.append(.{ .start = start, .end = end, .body = .html });
        }
    }

    /// Pop a container, setting its end.
    fn pop(self: *FirstPass, ix: usize) void {
        const cur_ix = self.tree.pop().?;
        self.tree.n(cur_ix).item.end = ix;
        const body = self.tree.n(cur_ix).item.body;
        if (body == .list and body.list.tight) {
            surgerizeTightList(&self.tree, cur_ix);
            self.begin_list_item = null;
        }
    }

    fn finishList(self: *FirstPass, ix: usize) void {
        self.finishEmptyListItem();
        const up = self.tree.peekUp();
        if (up != nil and self.tree.n(up).item.body == .list) self.pop(ix);
        if (self.last_line_blank) {
            const gp = self.tree.peekGrandparent();
            if (gp != nil) {
                const body = &self.tree.n(gp).item.body;
                if (body.* == .list) body.list.tight = false;
            }
            self.last_line_blank = false;
        }
    }

    fn finishEmptyListItem(self: *FirstPass) void {
        if (self.begin_list_item) |begin| {
            if (self.last_line_blank) {
                const up = self.tree.peekUp();
                if (up != nil and self.tree.n(up).item.body == .list_item) self.pop(begin);
            }
        }
        self.begin_list_item = null;
    }

    fn continueList(self: *FirstPass, start: usize, ch: u8, index: u64) Allocator.Error!void {
        self.finishEmptyListItem();
        const up = self.tree.peekUp();
        if (up != nil) {
            const body = &self.tree.n(up).item.body;
            if (body.* == .list) {
                if (body.list.ch == ch) {
                    if (self.last_line_blank) {
                        body.list.tight = false;
                        self.last_line_blank = false;
                    }
                    return;
                }
            }
            self.finishList(start);
        }
        _ = try self.tree.append(.{ .start = start, .end = 0, .body = .{ .list = .{ .tight = true, .ch = ch, .start = index } } });
        _ = try self.tree.push();
        self.last_line_blank = false;
    }

    fn parseHrule(self: *FirstPass, hrule_size: usize, ix: usize) Allocator.Error!usize {
        _ = try self.tree.append(.{ .start = ix, .end = ix + hrule_size, .body = .rule });
        return ix + hrule_size;
    }

    fn parseAtxHeading(self: *FirstPass, start: usize, atx_level: u8) Allocator.Error!usize {
        var ix = start;
        const heading_ix = try self.tree.append(.{ .start = start, .end = 0, .body = .root });
        ix += atx_level;
        const bytes = self.text;
        if (sc.scanEol(bytes[ix..])) |eol_bytes| {
            self.tree.n(heading_ix).item.end = ix + eol_bytes;
            self.tree.n(heading_ix).item.body = .{ .heading = atx_level };
            return ix + eol_bytes;
        }
        ix += sc.scanWhitespaceNoNl(bytes[ix..]);
        const header_start = ix;
        const header_node_idx = try self.tree.push();

        const r = try self.parseLine(ix, .disabled);
        ix = r[0];
        if (r[1]) |b| {
            if (b.body == .hard_break and b.body.hard_break) try self.tree.appendText(b.start, b.end, false);
        }
        const end = ix;
        const content_end = ix;
        self.tree.n(header_node_idx).item.end = end;

        var empty_text_node = false;
        const cur_ix = self.tree.cur;
        if (cur_ix != nil) {
            const header_text = bytes[header_start..content_end];
            var limit: usize = 0;
            {
                var p = header_text.len;
                while (p > 0) : (p -= 1) {
                    const c = header_text[p - 1];
                    if (!(c == '\n' or c == '\r' or c == ' ')) {
                        limit = p;
                        break;
                    }
                }
            }
            var closer: usize = 0;
            {
                var p = limit;
                while (p > 0) : (p -= 1) {
                    if (header_text[p - 1] != '#') {
                        closer = p;
                        break;
                    }
                }
            }
            if (closer == 0) {
                limit = closer;
            } else {
                const spaces = sc.scanRevCh(header_text[0..closer], ' ');
                if (spaces > 0) limit = closer - spaces;
            }
            self.tree.n(cur_ix).item.end = limit + header_start;
            if (limit == 0) empty_text_node = true;
        }

        if (empty_text_node) {
            _ = self.tree.removeNode();
        } else {
            _ = self.tree.pop();
        }
        self.tree.n(heading_ix).item.body = .{ .heading = atx_level };
        return end;
    }

    const RefdefLabelCtx = struct { fp: *const FirstPass };

    fn refdefLinebreak(ctx: ?*const anyopaque, bytes: []const u8) ?usize {
        const fp: *const FirstPass = @ptrCast(@alignCast(ctx.?));
        var line_start = LineStart.init(bytes);
        const current_container = scanContainers(&fp.tree, &line_start) == fp.tree.spineLen();
        if (line_start.scanSpace(4)) return line_start.bytesScanned();
        const bytes_scanned = line_start.bytesScanned();
        const suffix = bytes[bytes_scanned..];
        const interrupt = fp.scanParagraphInterruptPure(suffix, current_container);
        if (interrupt or (current_container and sc.scanSetextHeading(suffix) != null)) return null;
        return bytes_scanned;
    }

    fn parseRefdefLabel(self: *FirstPass, start: usize) Allocator.Error!?struct { usize, []const u8 } {
        return linklabel.scanLinkLabelRest(self.alloc, self.text[start..], .{ .ctx = self, .func = refdefLinebreak }, self.tree.isInTable());
    }

    const Refdef = struct { bytecount: usize, label: []const u8, def: LinkDef };

    fn parseRefdefTotal(self: *FirstPass, start: usize) Allocator.Error!?Refdef {
        const bytes = self.text[start..];
        if (sc.scanCh(bytes, '[') == 0) return null;
        const lr = (try self.parseRefdefLabel(start + 1)) orelse return null;
        var i = lr[0];
        i += 1;
        if (sc.scanCh(bytes[i..], ':') == 0) return null;
        i += 1;
        const sr = (try self.scanRefdef(start, start + i)) orelse return null;
        const key = try linklabel.foldKey(self.alloc, lr[1]);
        return .{ .bytecount = sr[0] + i, .label = key, .def = sr[1] };
    }

    /// Returns (bytes index, number of newlines)
    fn scanRefdefSpace(self: *FirstPass, bytes: []const u8, i_in: usize) ?struct { usize, usize } {
        var i = i_in;
        var newlines: usize = 0;
        while (true) {
            i += sc.scanWhitespaceNoNl(bytes[i..]);
            if (sc.scanEol(bytes[i..])) |eol_bytes| {
                i += eol_bytes;
                newlines += 1;
                if (newlines > 1) return null;
            } else break;
            var line_start = LineStart.init(bytes[i..]);
            const current_container = scanContainers(&self.tree, &line_start) == self.tree.spineLen();
            if (!line_start.scanSpace(4)) {
                const suffix = bytes[i + line_start.bytesScanned() ..];
                if (self.scanParagraphInterruptPure(suffix, current_container) or sc.scanSetextHeading(suffix) != null) return null;
            }
            i += line_start.bytesScanned();
        }
        return .{ i, newlines };
    }

    fn scanRefdefTitle(self: *FirstPass, text: []const u8) Allocator.Error!?struct { usize, []const u8 } {
        const bytes = text;
        if (bytes.len == 0) return null;
        const closing_delim: u8 = switch (bytes[0]) {
            '\'' => '\'',
            '"' => '"',
            '(' => ')',
            else => return null,
        };
        var bytecount: usize = 1;
        var linestart: usize = 1;
        var linebuf: ?std.ArrayList(u8) = null;

        while (bytecount < bytes.len) {
            const c = bytes[bytecount];
            if (c == '(' and closing_delim == ')') return null;
            if (c == '\n' or c == '\r') {
                if (linebuf == null) linebuf = .empty;
                try linebuf.?.appendSlice(self.alloc, text[linestart..bytecount]);
                try linebuf.?.append(self.alloc, '\n');
                bytecount += 1;
                if (c == '\r' and bytecount < bytes.len and bytes[bytecount] == '\n') bytecount += 1;
                var line_start = LineStart.init(bytes[bytecount..]);
                const current_container = scanContainers(&self.tree, &line_start) == self.tree.spineLen();
                if (!line_start.scanSpace(4)) {
                    const suffix = bytes[bytecount + line_start.bytesScanned() ..];
                    if (self.scanParagraphInterruptPure(suffix, current_container) or sc.scanSetextHeading(suffix) != null) return null;
                }
                line_start.scanAllSpace();
                bytecount += line_start.bytesScanned();
                linestart = bytecount;
                if (sc.scanBlankLine(bytes[bytecount..]) != null) return null;
            } else if (c == '\\') {
                bytecount += 1;
                if (bytecount < bytes.len) {
                    const d = bytes[bytecount];
                    if (d != '\r' and d != '\n') bytecount += 1;
                }
            } else if (c == closing_delim) {
                if (linebuf) |*lb| {
                    try lb.appendSlice(self.alloc, text[linestart..bytecount]);
                    return .{ bytecount + 1, lb.items };
                }
                return .{ bytecount + 1, text[linestart..bytecount] };
            } else {
                bytecount += 1;
            }
        }
        return null;
    }

    fn scanRefdef(self: *FirstPass, span_start: usize, start: usize) Allocator.Error!?struct { usize, LinkDef } {
        _ = span_start;
        const bytes = self.text;
        const sp = self.scanRefdefSpace(bytes, start) orelse return null;
        var i = sp[0];
        const ld = sc.scanLinkDest(self.text, i, LINK_MAX_NESTED_PARENS) orelse return null;
        if (ld[0] == 0) return null;
        const dest = try sc.unescape(self.alloc, ld[1], self.tree.isInTable());
        i += ld[0];

        var backup: struct { usize, LinkDef } = .{ i - start, .{ .dest = dest, .title = null } };

        var newlines: usize = undefined;
        if (self.scanRefdefSpace(bytes, i)) |r| {
            var nl = r[1];
            if (i == self.text.len) nl += 1;
            if (r[0] == i and nl == 0) return null;
            if (nl > 1) return backup;
            i = r[0];
            newlines = nl;
        } else return backup;

        if (try self.scanRefdefTitle(self.text[i..])) |t| {
            i += t[0];
            if (sc.scanBlankLine(bytes[i..]) != null) {
                backup[0] = i - start;
                backup[1].title = try sc.unescape(self.alloc, t[1], self.tree.isInTable());
                return backup;
            }
        }
        if (newlines > 0) return backup;
        return null;
    }

    fn scanParagraphInterrupt(self: *FirstPass, bytes: []const u8, current_container: bool) Allocator.Error!bool {
        return self.scanParagraphInterruptPure(bytes, current_container);
    }

    /// `scan_paragraph_interrupt` (tables enabled). Allocation-free: the
    /// table-head scan only needs the column count.
    pub fn scanParagraphInterruptPure(self: *const FirstPass, bytes: []const u8, current_container: bool) bool {
        if (scanParagraphInterruptNoTable(bytes, current_container, &self.tree)) return true;
        if (!(bytes.len > 0 and bytes[0] == '|')) return false;

        var pipes: usize = 0;
        var next_line_ix: usize = 0;
        var bsesc = false;
        var last_pipe_ix: usize = 0;
        for (bytes, 0..) |byte, i| {
            switch (byte) {
                '\\' => {
                    bsesc = true;
                    continue;
                },
                '|' => if (!bsesc) {
                    pipes += 1;
                    last_pipe_ix = i;
                },
                '\r', '\n' => {
                    next_line_ix = i + sc.scanEol(bytes[i..]).?;
                    break;
                },
                else => {},
            }
            bsesc = false;
        }
        if (next_line_ix == 0) return false;

        var line_start = LineStart.init(bytes[next_line_ix..]);
        if (scanContainers(&self.tree, &line_start) != self.tree.spineLen()) return false;
        const table_head_ix = next_line_ix + line_start.bytesScanned();
        const th = sc.scanTableHeadCount(bytes[table_head_ix..]);
        if (th[0] == 0) return false;
        const header_count = countHeaderCols(bytes, pipes, 0, last_pipe_ix);
        return th[1] == header_count;
    }
};

fn countHeaderCols(bytes: []const u8, pipes_in: usize, start_in: usize, last_pipe_ix: usize) usize {
    var pipes = pipes_in;
    var start = start_in;
    start += sc.scanWhitespaceNoNl(bytes[start..]);
    if (bytes[start] == '|') pipes -= 1;
    if (sc.scanBlankLine(bytes[last_pipe_ix + 1 ..]) != null) return pipes;
    return pipes + 1;
}

pub fn scanParagraphInterruptNoTable(bytes: []const u8, current_container: bool, tree: *const Tree) bool {
    if (sc.scanEol(bytes) != null) return true;
    if (sc.scanHrule(bytes).ok) return true;
    if (sc.scanAtxHeading(bytes) != null) return true;
    if (sc.scanCodeFence(bytes) != null) return true;
    if (sc.scanBlockquoteStart(bytes) != null) return true;
    if (sc.scanListitem(bytes)) |li| {
        const ix = li[0];
        const delim = li[1];
        const index = li[2];
        if (!current_container or tree.isInTable() or
            ((delim == '*' or delim == '-' or delim == '+' or index == 1) and sc.scanBlankLine(bytes[ix..]) == null))
            return true;
    }
    if (bytes.len > 0 and bytes[0] == '<' and (sc.getHtmlEndTag(bytes[1..]) != null or sc.startsHtmlBlockType6(bytes[1..]))) return true;
    return false;
}

fn surgerizeTightList(tree: *Tree, list_ix: Ix) void {
    var list_item = tree.n(list_ix).child;
    while (list_item != nil) {
        const listitem_ix = list_item;
        const firstborn = tree.n(listitem_ix).child;
        if (firstborn != nil) {
            if (tree.n(firstborn).item.body == .paragraph) {
                tree.n(listitem_ix).child = tree.n(firstborn).child;
            }
            var list_item_child = firstborn;
            var node_to_repoint: Ix = nil;
            while (list_item_child != nil) {
                const child_ix = list_item_child;
                var repoint_ix = child_ix;
                if (tree.n(child_ix).item.body == .paragraph) {
                    const child_firstborn = tree.n(child_ix).child;
                    if (child_firstborn != nil) {
                        if (node_to_repoint != nil) tree.n(node_to_repoint).next = child_firstborn;
                        var child_lastborn = child_firstborn;
                        while (tree.n(child_lastborn).next != nil) child_lastborn = tree.n(child_lastborn).next;
                        repoint_ix = child_lastborn;
                    }
                }
                node_to_repoint = repoint_ix;
                tree.n(repoint_ix).next = tree.n(child_ix).next;
                list_item_child = tree.n(child_ix).next;
            }
        }
        list_item = tree.n(listitem_ix).next;
    }
}

fn delimRunCanOpen(s: []const u8, suffix: []const u8, run_len: usize, ix: usize, mode: TableParseMode) bool {
    const next = unicode.decodeFirst(suffix[run_len..]) orelse return false;
    const next_char = next.cp;
    if (unicode.isWhitespace(next_char)) return false;
    if (ix == 0) return true;
    if (mode == .active) {
        if (std.mem.endsWith(u8, s[0..ix], "|") and !std.mem.endsWith(u8, s[0..ix], "\\|")) return true;
        if (next_char == '|') return false;
    }
    const delim = suffix[0];
    if (delim == '*' and !sc.isPunctuation(next_char)) return true;
    if (delim == '~' and run_len > 1) return true;
    const prev_char = unicode.decodeLast(s[0..ix]).?.cp;
    if (delim == '~' and prev_char == '~' and !sc.isPunctuation(next_char)) return true;
    return unicode.isWhitespace(prev_char) or
        (sc.isPunctuation(prev_char) and (delim != '\'' or !(prev_char == ']' or prev_char == ')')));
}

fn delimRunCanClose(s: []const u8, suffix: []const u8, run_len: usize, ix: usize, mode: TableParseMode) bool {
    if (ix == 0) return false;
    const prev_char = unicode.decodeLast(s[0..ix]).?.cp;
    if (unicode.isWhitespace(prev_char)) return false;
    const next = unicode.decodeFirst(suffix[run_len..]) orelse return true;
    const next_char = next.cp;
    if (mode == .active) {
        if (std.mem.endsWith(u8, s[0..ix], "|") and !std.mem.endsWith(u8, s[0..ix], "\\|")) return false;
        if (next_char == '|') return true;
    }
    const delim = suffix[0];
    if ((delim == '*' or (delim == '~' and run_len > 1)) and !sc.isPunctuation(prev_char)) return true;
    if (delim == '~' and prev_char == '~') return true;
    return unicode.isWhitespace(next_char) or sc.isPunctuation(next_char);
}
