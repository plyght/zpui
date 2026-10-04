//! Port of the Rust `tree-sitter-highlight` 0.26 crate (Rust-only upstream):
//! `HighlightConfiguration` and the layered `HighlightIter` event stream,
//! including local-variable scopes, injections (with `injection.combined`),
//! and the exact capture-precedence rules. The structure mirrors
//! highlight.rs so behavior can be compared line by line.

const std = @import("std");
const c = @import("ts_c");
const query_mod = @import("query.zig");
const Query = query_mod.Query;
const Allocator = std.mem.Allocator;

pub const Highlight = u16;

pub const Event = union(enum) {
    source: struct { start: usize, end: usize },
    highlight_start: Highlight,
    highlight_end,
};

pub const Error = error{ Cancelled, InvalidLanguage, InvalidQuery, OutOfMemory };

const max_u32 = std.math.maxInt(u32);
const cancellation_check_interval = 100;

/// Immutable after `configure`; shareable between threads.
pub const Configuration = struct {
    language: *const c.TSLanguage,
    language_name: []const u8,
    query: Query,
    combined_injections_query: ?Query,
    locals_pattern_index: usize,
    highlights_pattern_index: usize,
    highlight_indices: []?Highlight,
    non_local_variable_patterns: []bool,
    injection_content_capture_index: ?u32 = null,
    injection_language_capture_index: ?u32 = null,
    local_scope_capture_index: ?u32 = null,
    local_def_capture_index: ?u32 = null,
    local_def_value_capture_index: ?u32 = null,
    local_ref_capture_index: ?u32 = null,
    gpa: Allocator,

    pub fn init(
        gpa: Allocator,
        language: *const c.TSLanguage,
        name: []const u8,
        highlights_query: []const u8,
        injection_query: []const u8,
        locals_query: []const u8,
    ) Error!Configuration {
        const query_source = try std.mem.concat(gpa, u8, &.{ injection_query, locals_query, highlights_query });
        defer gpa.free(query_source);
        const locals_query_offset = injection_query.len;
        const highlights_query_offset = injection_query.len + locals_query.len;

        var query = try Query.init(gpa, language, query_source);
        errdefer query.deinit();
        var locals_pattern_index: usize = 0;
        var highlights_pattern_index: usize = 0;
        for (0..query.patternCount()) |i| {
            const offset = query.startByteForPattern(i);
            if (offset < highlights_query_offset) {
                highlights_pattern_index += 1;
                if (offset < locals_query_offset) locals_pattern_index += 1;
            }
        }

        var combined = try Query.init(gpa, language, injection_query);
        var combined_owned = true;
        defer if (combined_owned) combined.deinit();
        var has_combined = false;
        for (0..locals_pattern_index) |pi| {
            var is_combined = false;
            for (query.propertySettings(pi)) |s| {
                if (std.mem.eql(u8, s.key, "injection.combined")) is_combined = true;
            }
            if (is_combined) {
                has_combined = true;
                query.disablePattern(pi);
            } else {
                combined.disablePattern(pi);
            }
        }

        const non_local = try gpa.alloc(bool, query.patternCount());
        errdefer gpa.free(non_local);
        for (non_local, 0..) |*nl, i| {
            nl.* = false;
            for (query.propertyPredicates(i)) |pp| {
                if (!pp.positive and std.mem.eql(u8, pp.property.key, "local")) nl.* = true;
            }
        }

        const highlight_indices = try gpa.alloc(?Highlight, query.capture_names.len);
        @memset(highlight_indices, null);
        errdefer gpa.free(highlight_indices);
        const owned_name = try gpa.dupe(u8, name);

        var self: Configuration = .{
            .language = language,
            .language_name = owned_name,
            .query = query,
            .combined_injections_query = if (has_combined) combined else null,
            .locals_pattern_index = locals_pattern_index,
            .highlights_pattern_index = highlights_pattern_index,
            .highlight_indices = highlight_indices,
            .non_local_variable_patterns = non_local,
            .gpa = gpa,
        };
        if (has_combined) combined_owned = false;
        for (query.capture_names, 0..) |cap, i| {
            const idx: u32 = @intCast(i);
            if (std.mem.eql(u8, cap, "injection.content")) self.injection_content_capture_index = idx;
            if (std.mem.eql(u8, cap, "injection.language")) self.injection_language_capture_index = idx;
            if (std.mem.eql(u8, cap, "local.definition")) self.local_def_capture_index = idx;
            if (std.mem.eql(u8, cap, "local.definition-value")) self.local_def_value_capture_index = idx;
            if (std.mem.eql(u8, cap, "local.reference")) self.local_ref_capture_index = idx;
            if (std.mem.eql(u8, cap, "local.scope")) self.local_scope_capture_index = idx;
        }
        return self;
    }

    pub fn deinit(self: *Configuration) void {
        self.query.deinit();
        if (self.combined_injections_query) |*q| q.deinit();
        self.gpa.free(self.highlight_indices);
        self.gpa.free(self.non_local_variable_patterns);
        self.gpa.free(self.language_name);
    }

    /// Capture names used by the configuration's queries.
    pub fn names(self: *const Configuration) []const []const u8 {
        return self.query.capture_names;
    }

    /// `HighlightConfiguration::configure`: map every capture name to the
    /// recognized name sharing the most dot-separated parts (all parts of the
    /// recognized name must occur in the capture name).
    pub fn configure(self: *Configuration, recognized_names: []const []const u8) void {
        for (self.query.capture_names, self.highlight_indices) |capture_name, *slot| {
            var best_index: ?Highlight = null;
            var best_len: usize = 0;
            for (recognized_names, 0..) |recognized, i| {
                var len: usize = 0;
                var matches = true;
                var parts = std.mem.splitScalar(u8, recognized, '.');
                while (parts.next()) |part| {
                    len += 1;
                    if (!containsPart(capture_name, part)) {
                        matches = false;
                        break;
                    }
                }
                if (matches and len > best_len) {
                    best_index = @intCast(i);
                    best_len = len;
                }
            }
            slot.* = best_index;
        }
    }
};

fn containsPart(capture_name: []const u8, part: []const u8) bool {
    var it = std.mem.splitScalar(u8, capture_name, '.');
    while (it.next()) |p| if (std.mem.eql(u8, p, part)) return true;
    return false;
}

/// Resolves an injection language name to a configuration (or null).
pub const InjectionCallback = struct {
    context: *anyopaque,
    resolve: *const fn (context: *anyopaque, name: []const u8) ?*const Configuration,
};

const Capture = struct {
    match: c.TSQueryMatch,
    capture_index: u32,

    fn capture(self: Capture) c.TSQueryCapture {
        return self.match.captures[self.capture_index];
    }
};

/// `Peekable<_QueryCaptures>`: next/peek drive `ts_query_cursor_next_capture`
/// in exactly the same order as the Rust iterator.
const Captures = struct {
    cursor: *c.TSQueryCursor,
    query: *const Query,
    source: []const u8,
    peeked: ?(?Capture) = null,

    fn nextRaw(self: *Captures) ?Capture {
        while (true) {
            var m: c.TSQueryMatch = undefined;
            var capture_index: u32 = 0;
            if (!c.ts_query_cursor_next_capture(self.cursor, &m, &capture_index)) return null;
            if (self.query.satisfiesTextPredicates(&m, self.source)) return .{ .match = m, .capture_index = capture_index };
            c.ts_query_cursor_remove_match(self.cursor, m.id);
        }
    }

    fn peek(self: *Captures) ?Capture {
        if (self.peeked == null) self.peeked = self.nextRaw();
        return self.peeked.?;
    }

    fn next(self: *Captures) ?Capture {
        if (self.peeked) |p| {
            self.peeked = null;
            return p;
        }
        return self.nextRaw();
    }
};

const LocalDef = struct {
    name: []const u8,
    value_start: usize,
    value_end: usize,
    highlight: ?Highlight,
};

const LocalScope = struct {
    inherits: bool,
    start: usize,
    end: usize,
    local_defs: std.ArrayList(LocalDef) = .empty,
};

const Layer = struct {
    tree: *c.TSTree,
    cursor: *c.TSQueryCursor,
    captures: Captures,
    config: *const Configuration,
    highlight_end_stack: std.ArrayList(usize) = .empty,
    scope_stack: std.ArrayList(LocalScope) = .empty,
    ranges: []c.TSRange,
    depth: usize,

    fn destroy(self: *Layer, gpa: Allocator) void {
        for (self.scope_stack.items) |*s| s.local_defs.deinit(gpa);
        self.scope_stack.deinit(gpa);
        self.highlight_end_stack.deinit(gpa);
        gpa.free(self.ranges);
        c.ts_query_cursor_delete(self.cursor);
        c.ts_tree_delete(self.tree);
        gpa.destroy(self);
    }

    const SortKey = struct {
        offset: usize,
        is_start: bool,
        depth: isize,

        fn lessThan(a: SortKey, b: SortKey) bool {
            if (a.offset != b.offset) return a.offset < b.offset;
            if (a.is_start != b.is_start) return !a.is_start; // false < true
            return a.depth < b.depth;
        }
    };

    /// Scope boundaries sorted by offset; ends before starts; deeper layers first.
    fn sortKey(self: *Layer) ?SortKey {
        const depth = -@as(isize, @intCast(self.depth));
        const next_start: ?usize = if (self.captures.peek()) |cap| c.ts_node_start_byte(cap.capture().node) else null;
        const next_end: ?usize = if (self.highlight_end_stack.items.len > 0) self.highlight_end_stack.items[self.highlight_end_stack.items.len - 1] else null;
        if (next_start) |s| {
            if (next_end) |e| {
                return if (s < e) .{ .offset = s, .is_start = true, .depth = depth } else .{ .offset = e, .is_start = false, .depth = depth };
            }
            return .{ .offset = s, .is_start = true, .depth = depth };
        }
        if (next_end) |e| return .{ .offset = e, .is_start = false, .depth = depth };
        return null;
    }
};

const ReadPayload = struct { source: []const u8 };

fn readInput(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
    const p: *const ReadPayload = @ptrCast(@alignCast(payload.?));
    if (byte_index < p.source.len) {
        bytes_read.* = @intCast(p.source.len - byte_index);
        return p.source.ptr + byte_index;
    }
    bytes_read.* = 0;
    return "";
}

fn progressCallback(state: [*c]c.TSParseState) callconv(.c) bool {
    const flag: ?*const std.atomic.Value(usize) = @ptrCast(@alignCast(state.*.payload));
    if (flag) |f| return f.load(.seq_cst) != 0;
    return false;
}

pub const Highlighter = struct {
    gpa: Allocator,
    parser: *c.TSParser,

    pub fn init(gpa: Allocator) Error!Highlighter {
        return .{ .gpa = gpa, .parser = c.ts_parser_new() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Highlighter) void {
        c.ts_parser_delete(self.parser);
    }

    /// Iterate over the highlighted regions of `source`.
    pub fn highlight(
        self: *Highlighter,
        config: *const Configuration,
        source: []const u8,
        cancellation_flag: ?*const std.atomic.Value(usize),
        injection_callback: InjectionCallback,
    ) Error!HighlightIter {
        var iter: HighlightIter = .{
            .gpa = self.gpa,
            .source = source,
            .language_name = config.language_name,
            .highlighter = self,
            .injection_callback = injection_callback,
            .cancellation_flag = cancellation_flag,
        };
        errdefer iter.deinit();
        const full = try self.gpa.alloc(c.TSRange, 1);
        full[0] = .{
            .start_byte = 0,
            .end_byte = max_u32,
            .start_point = .{ .row = 0, .column = 0 },
            .end_point = .{ .row = max_u32, .column = max_u32 },
        };
        try iter.newLayers(null, config, 0, full);
        std.debug.assert(iter.layers.items.len != 0);
        iter.sortLayers();
        return iter;
    }
};

pub const HighlightIter = struct {
    gpa: Allocator,
    source: []const u8,
    language_name: []const u8,
    byte_offset: usize = 0,
    highlighter: *Highlighter,
    injection_callback: InjectionCallback,
    cancellation_flag: ?*const std.atomic.Value(usize),
    layers: std.ArrayList(*Layer) = .empty,
    iter_count: usize = 0,
    next_event: ?Event = null,
    last_highlight_range: ?struct { usize, usize, usize } = null,

    pub fn deinit(self: *HighlightIter) void {
        for (self.layers.items) |l| l.destroy(self.gpa);
        self.layers.deinit(self.gpa);
    }

    /// `HighlightIterLayer::new`: parse `ranges` with `config` and append the
    /// resulting layer(s) — combined injections are processed eagerly — to
    /// `out`. Takes ownership of `ranges_in`.
    fn newLayersInto(
        self: *HighlightIter,
        out: *std.ArrayList(*Layer),
        parent_name: ?[]const u8,
        config_in: *const Configuration,
        depth_in: usize,
        ranges_in: []c.TSRange,
    ) Error!void {
        const gpa = self.gpa;
        const QueueItem = struct { config: *const Configuration, depth: usize, ranges: []c.TSRange };
        var queue: std.ArrayList(QueueItem) = .empty;
        defer {
            for (queue.items) |q| gpa.free(q.ranges);
            queue.deinit(gpa);
        }
        var config = config_in;
        var depth = depth_in;
        var ranges: ?[]c.TSRange = ranges_in;
        defer if (ranges) |r| gpa.free(r);
        const parser = self.highlighter.parser;

        while (true) {
            const rs = ranges.?;
            if (c.ts_parser_set_included_ranges(parser, rs.ptr, @intCast(rs.len))) {
                if (!c.ts_parser_set_language(parser, config.language)) return error.InvalidLanguage;
                var payload: ReadPayload = .{ .source = self.source };
                const input: c.TSInput = .{
                    .payload = &payload,
                    .read = readInput,
                    .encoding = c.TSInputEncodingUTF8,
                    .decode = null,
                };
                const options: c.TSParseOptions = .{
                    .payload = @ptrCast(@constCast(self.cancellation_flag)),
                    .progress_callback = progressCallback,
                };
                const tree = c.ts_parser_parse_with_options(parser, null, input, options) orelse return error.Cancelled;
                var tree_owned = true;
                defer if (tree_owned) c.ts_tree_delete(tree);
                const cursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
                var cursor_owned = true;
                defer if (cursor_owned) c.ts_query_cursor_delete(cursor);

                // Process combined injections.
                if (config.combined_injections_query) |*combined| {
                    const n = combined.patternCount();
                    const Entry = struct { lang: ?[]const u8 = null, nodes: std.ArrayList(c.TSNode) = .empty, include_children: bool = false };
                    const entries = try gpa.alloc(Entry, n);
                    for (entries) |*e| e.* = .{};
                    defer {
                        for (entries) |*e| e.nodes.deinit(gpa);
                        gpa.free(entries);
                    }
                    c.ts_query_cursor_exec(cursor, combined.ptr, c.ts_tree_root_node(tree));
                    var m: c.TSQueryMatch = undefined;
                    while (c.ts_query_cursor_next_match(cursor, &m)) {
                        if (!combined.satisfiesTextPredicates(&m, self.source)) continue;
                        const entry = &entries[m.pattern_index];
                        const inj = injectionForMatch(config, parent_name, combined, &m, self.source);
                        if (inj.language_name) |l| entry.lang = l;
                        if (inj.content_node) |node| try entry.nodes.append(gpa, node);
                        entry.include_children = inj.include_children;
                    }
                    for (entries) |*e| {
                        const lang = e.lang orelse continue;
                        if (e.nodes.items.len == 0) continue;
                        if (self.injection_callback.resolve(self.injection_callback.context, lang)) |next_config| {
                            const r = try intersectRanges(gpa, rs, e.nodes.items, e.include_children);
                            if (r.len > 0) {
                                queue.append(gpa, .{ .config = next_config, .depth = depth + 1, .ranges = r }) catch |err| {
                                    gpa.free(r);
                                    return err;
                                };
                            } else gpa.free(r);
                        }
                    }
                }

                c.ts_query_cursor_exec(cursor, config.query.ptr, c.ts_tree_root_node(tree));
                const layer = try gpa.create(Layer);
                layer.* = .{
                    .tree = tree,
                    .cursor = cursor,
                    .captures = .{ .cursor = cursor, .query = &config.query, .source = self.source },
                    .config = config,
                    .ranges = rs,
                    .depth = depth,
                };
                tree_owned = false;
                cursor_owned = false;
                ranges = null;
                errdefer layer.destroy(gpa);
                try layer.scope_stack.append(gpa, .{ .inherits = false, .start = 0, .end = std.math.maxInt(usize) });
                try out.append(gpa, layer);
            }

            if (ranges) |r| gpa.free(r);
            ranges = null;
            if (queue.items.len == 0) break;
            const item = queue.orderedRemove(0);
            config = item.config;
            depth = item.depth;
            ranges = item.ranges;
        }
    }

    fn newLayers(self: *HighlightIter, parent_name: ?[]const u8, config: *const Configuration, depth: usize, ranges: []c.TSRange) Error!void {
        try self.newLayersInto(&self.layers, parent_name, config, depth, ranges);
    }

    fn emitEvent(self: *HighlightIter, offset: usize, event: ?Event) ?Event {
        var result: ?Event = null;
        if (self.byte_offset < offset) {
            result = .{ .source = .{ .start = self.byte_offset, .end = offset } };
            self.byte_offset = offset;
            self.next_event = event;
        } else {
            result = event;
        }
        self.sortLayers();
        return result;
    }

    fn sortLayers(self: *HighlightIter) void {
        const layers = &self.layers;
        while (layers.items.len > 0) {
            if (layers.items[0].sortKey()) |key| {
                var i: usize = 0;
                while (i + 1 < layers.items.len) {
                    if (layers.items[i + 1].sortKey()) |next_key| {
                        if (Layer.SortKey.lessThan(next_key, key)) {
                            i += 1;
                            continue;
                        }
                    }
                    break;
                }
                if (i > 0) std.mem.rotate(*Layer, layers.items[0 .. i + 1], 1);
                break;
            }
            const layer = layers.orderedRemove(0);
            layer.destroy(self.gpa);
        }
    }

    fn insertLayer(self: *HighlightIter, layer: *Layer) Error!void {
        if (layer.sortKey()) |key| {
            var i: usize = 1;
            while (i < self.layers.items.len) {
                if (self.layers.items[i].sortKey()) |key_i| {
                    if (Layer.SortKey.lessThan(key, key_i)) {
                        try self.layers.insert(self.gpa, i, layer);
                        return;
                    }
                    i += 1;
                } else {
                    const removed = self.layers.orderedRemove(i);
                    removed.destroy(self.gpa);
                }
            }
            try self.layers.append(self.gpa, layer);
        } else {
            layer.destroy(self.gpa);
        }
    }

    pub fn next(self: *HighlightIter) Error!?Event {
        main: while (true) {
            if (self.next_event) |e| {
                self.next_event = null;
                return e;
            }

            if (self.cancellation_flag) |flag| {
                self.iter_count += 1;
                if (self.iter_count >= cancellation_check_interval) {
                    self.iter_count = 0;
                    if (flag.load(.monotonic) != 0) return error.Cancelled;
                }
            }

            if (self.layers.items.len == 0) {
                if (self.byte_offset < self.source.len) {
                    const result: Event = .{ .source = .{ .start = self.byte_offset, .end = self.source.len } };
                    self.byte_offset = self.source.len;
                    return result;
                }
                return null;
            }

            var range_start: usize = undefined;
            var range_end: usize = undefined;
            const layer = self.layers.items[0];
            if (layer.captures.peek()) |next_cap| {
                const node = next_cap.capture().node;
                range_start = c.ts_node_start_byte(node);
                range_end = c.ts_node_end_byte(node);
                if (layer.highlight_end_stack.items.len > 0) {
                    const end_byte = layer.highlight_end_stack.items[layer.highlight_end_stack.items.len - 1];
                    if (end_byte <= range_start) {
                        _ = layer.highlight_end_stack.pop();
                        return self.emitEvent(end_byte, .highlight_end);
                    }
                }
            } else {
                if (layer.highlight_end_stack.pop()) |end_byte| {
                    return self.emitEvent(end_byte, .highlight_end);
                }
                return self.emitEvent(self.source.len, null);
            }

            var cur = layer.captures.next().?;
            var capture = cur.capture();

            // Injection pattern.
            if (cur.match.pattern_index < layer.config.locals_pattern_index) {
                const inj = injectionForMatch(layer.config, self.language_name, &layer.config.query, &cur.match, self.source);
                c.ts_query_cursor_remove_match(layer.cursor, cur.match.id);
                if (inj.language_name) |lang| if (inj.content_node) |content| {
                    if (self.injection_callback.resolve(self.injection_callback.context, lang)) |config| {
                        const ranges = try intersectRanges(self.gpa, self.layers.items[0].ranges, &.{content}, inj.include_children);
                        if (ranges.len > 0) {
                            var new_layers: std.ArrayList(*Layer) = .empty;
                            defer new_layers.deinit(self.gpa);
                            errdefer for (new_layers.items) |l| l.destroy(self.gpa);
                            try self.newLayersInto(&new_layers, self.language_name, config, self.layers.items[0].depth + 1, ranges);
                            while (new_layers.items.len > 0) {
                                const l = new_layers.orderedRemove(0);
                                self.insertLayer(l) catch |err| {
                                    l.destroy(self.gpa);
                                    return err;
                                };
                            }
                        } else self.gpa.free(ranges);
                    }
                };
                self.sortLayers();
                continue :main;
            }

            // Pop ended local scopes.
            while (range_start > layer.scope_stack.items[layer.scope_stack.items.len - 1].end) {
                const s = layer.scope_stack.pop().?;
                var defs = s.local_defs;
                defs.deinit(self.gpa);
            }

            // Local variable tracking.
            var reference_highlight: ?Highlight = null;
            var definition_highlight: ?struct { scope: usize, def: usize } = null;
            while (cur.match.pattern_index < layer.config.highlights_pattern_index) {
                const cfg = layer.config;
                if (cfg.local_scope_capture_index != null and capture.index == cfg.local_scope_capture_index.?) {
                    definition_highlight = null;
                    var scope: LocalScope = .{ .inherits = true, .start = range_start, .end = range_end };
                    for (cfg.query.propertySettings(cur.match.pattern_index)) |prop| {
                        if (std.mem.eql(u8, prop.key, "local.scope-inherits")) {
                            scope.inherits = if (prop.value) |v| std.mem.eql(u8, v, "true") else true;
                        }
                    }
                    try layer.scope_stack.append(self.gpa, scope);
                } else if (cfg.local_def_capture_index != null and capture.index == cfg.local_def_capture_index.?) {
                    reference_highlight = null;
                    definition_highlight = null;
                    const scope_ix = layer.scope_stack.items.len - 1;
                    const scope = &layer.scope_stack.items[scope_ix];
                    var value_start: usize = 0;
                    var value_end: usize = 0;
                    for (cur.match.captures[0..cur.match.capture_count]) |cap| {
                        if (cfg.local_def_value_capture_index != null and cap.index == cfg.local_def_value_capture_index.?) {
                            value_start = c.ts_node_start_byte(cap.node);
                            value_end = c.ts_node_end_byte(cap.node);
                        }
                    }
                    const name = self.source[range_start..range_end];
                    if (std.unicode.utf8ValidateSlice(name)) {
                        try scope.local_defs.append(self.gpa, .{ .name = name, .value_start = value_start, .value_end = value_end, .highlight = null });
                        definition_highlight = .{ .scope = scope_ix, .def = scope.local_defs.items.len - 1 };
                    }
                } else if (cfg.local_ref_capture_index != null and capture.index == cfg.local_ref_capture_index.? and definition_highlight == null) {
                    definition_highlight = null;
                    const name = self.source[range_start..range_end];
                    if (std.unicode.utf8ValidateSlice(name)) {
                        var si = layer.scope_stack.items.len;
                        scopes: while (si > 0) {
                            si -= 1;
                            const scope = &layer.scope_stack.items[si];
                            var di = scope.local_defs.items.len;
                            while (di > 0) {
                                di -= 1;
                                const def = scope.local_defs.items[di];
                                if (std.mem.eql(u8, def.name, name) and range_start >= def.value_end) {
                                    reference_highlight = def.highlight;
                                    break :scopes;
                                }
                            }
                            if (!scope.inherits) break;
                        }
                    }
                }

                // Continue processing any additional matches for the same node.
                if (layer.captures.peek()) |next_cap| {
                    const next_capture = next_cap.capture();
                    if (next_capture.node.id == capture.node.id) {
                        capture = next_capture;
                        cur = layer.captures.next().?;
                        continue;
                    }
                }

                self.sortLayers();
                continue :main;
            }

            // Skip a range already highlighted by an earlier pattern or a deeper layer.
            if (self.last_highlight_range) |last| {
                const last_start, const last_end, const last_depth = last;
                if (range_start == last_start and range_end == last_end and layer.depth < last_depth) {
                    self.sortLayers();
                    continue :main;
                }
            }

            // Later highlighting patterns for the same node win.
            while (layer.captures.peek()) |next_cap| {
                const next_capture = next_cap.capture();
                if (next_capture.node.id != capture.node.id) break;
                const following = layer.captures.next().?;
                if ((definition_highlight != null or reference_highlight != null) and
                    layer.config.non_local_variable_patterns[following.match.pattern_index])
                {
                    continue;
                }
                c.ts_query_cursor_remove_match(layer.cursor, cur.match.id);
                capture = next_capture;
                cur = following;
            }

            const current_highlight = layer.config.highlight_indices[capture.index];

            if (definition_highlight) |dh| {
                layer.scope_stack.items[dh.scope].local_defs.items[dh.def].highlight = current_highlight;
            }

            if (reference_highlight orelse current_highlight) |hl| {
                self.last_highlight_range = .{ range_start, range_end, layer.depth };
                try layer.highlight_end_stack.append(self.gpa, range_end);
                return self.emitEvent(range_start, .{ .highlight_start = hl });
            }

            self.sortLayers();
        }
    }
};

const Injection = struct {
    language_name: ?[]const u8,
    content_node: ?c.TSNode,
    include_children: bool,
};

fn injectionForMatch(
    config: *const Configuration,
    parent_name: ?[]const u8,
    query: *const Query,
    m: *const c.TSQueryMatch,
    source: []const u8,
) Injection {
    var language_name: ?[]const u8 = null;
    var content_node: ?c.TSNode = null;
    for (m.captures[0..m.capture_count]) |cap| {
        if (config.injection_language_capture_index != null and cap.index == config.injection_language_capture_index.?) {
            const text = query_mod.nodeText(cap.node, source);
            language_name = if (std.unicode.utf8ValidateSlice(text)) text else null;
        } else if (config.injection_content_capture_index != null and cap.index == config.injection_content_capture_index.?) {
            content_node = cap.node;
        }
    }
    var include_children = false;
    for (query.propertySettings(m.pattern_index)) |prop| {
        if (std.mem.eql(u8, prop.key, "injection.language")) {
            if (language_name == null) language_name = prop.value;
        } else if (std.mem.eql(u8, prop.key, "injection.self")) {
            if (language_name == null) language_name = config.language_name;
        } else if (std.mem.eql(u8, prop.key, "injection.parent")) {
            if (language_name == null) language_name = parent_name;
        } else if (std.mem.eql(u8, prop.key, "injection.include-children")) {
            include_children = true;
        }
    }
    return .{ .language_name = language_name, .content_node = content_node, .include_children = include_children };
}

fn nodeRange(node: c.TSNode) c.TSRange {
    return .{
        .start_byte = c.ts_node_start_byte(node),
        .end_byte = c.ts_node_end_byte(node),
        .start_point = c.ts_node_start_point(node),
        .end_point = c.ts_node_end_point(node),
    };
}

/// `HighlightIterLayer::intersect_ranges`.
fn intersectRanges(gpa: Allocator, parent_ranges: []const c.TSRange, nodes: []const c.TSNode, includes_children: bool) Error![]c.TSRange {
    var result: std.ArrayList(c.TSRange) = .empty;
    errdefer result.deinit(gpa);
    var parent_ix: usize = 0;
    var parent_range = parent_ranges[0];
    var excluded: std.ArrayList(c.TSRange) = .empty;
    defer excluded.deinit(gpa);

    for (nodes) |node| {
        var preceding_range: c.TSRange = .{
            .start_byte = 0,
            .start_point = .{ .row = 0, .column = 0 },
            .end_byte = c.ts_node_start_byte(node),
            .end_point = c.ts_node_start_point(node),
        };
        const following_range: c.TSRange = .{
            .start_byte = c.ts_node_end_byte(node),
            .start_point = c.ts_node_end_point(node),
            .end_byte = max_u32,
            .end_point = .{ .row = max_u32, .column = max_u32 },
        };

        excluded.clearRetainingCapacity();
        if (!includes_children) {
            var cursor = c.ts_tree_cursor_new(node);
            defer c.ts_tree_cursor_delete(&cursor);
            const count = c.ts_node_child_count(node);
            _ = c.ts_tree_cursor_goto_first_child(&cursor);
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                try excluded.append(gpa, nodeRange(c.ts_tree_cursor_current_node(&cursor)));
                _ = c.ts_tree_cursor_goto_next_sibling(&cursor);
            }
        }
        try excluded.append(gpa, following_range);

        for (excluded.items) |excluded_range| {
            var range: c.TSRange = .{
                .start_byte = preceding_range.end_byte,
                .start_point = preceding_range.end_point,
                .end_byte = excluded_range.start_byte,
                .end_point = excluded_range.start_point,
            };
            preceding_range = excluded_range;

            if (range.end_byte < parent_range.start_byte) continue;

            while (parent_range.start_byte <= range.end_byte) {
                if (parent_range.end_byte > range.start_byte) {
                    if (range.start_byte < parent_range.start_byte) {
                        range.start_byte = parent_range.start_byte;
                        range.start_point = parent_range.start_point;
                    }
                    if (parent_range.end_byte < range.end_byte) {
                        if (range.start_byte < parent_range.end_byte) {
                            try result.append(gpa, .{
                                .start_byte = range.start_byte,
                                .start_point = range.start_point,
                                .end_byte = parent_range.end_byte,
                                .end_point = parent_range.end_point,
                            });
                        }
                        range.start_byte = parent_range.end_byte;
                        range.start_point = parent_range.end_point;
                    } else {
                        if (range.start_byte < range.end_byte) try result.append(gpa, range);
                        break;
                    }
                }
                parent_ix += 1;
                if (parent_ix < parent_ranges.len) {
                    parent_range = parent_ranges[parent_ix];
                } else {
                    return result.toOwnedSlice(gpa);
                }
            }
        }
    }
    return result.toOwnedSlice(gpa);
}
