//! zeron syntax highlighting (port of zeron's `crates/syntax`).
//!
//! Tree-sitter grammars (vendor/tree-sitter) plus a Zig port of
//! `tree-sitter-highlight` (highlight.zig). The public contract matches the
//! Rust crate: detect a language from a path / fence info string / shebang,
//! highlight a whole document, and get back line-relative, sorted,
//! non-overlapping spans of `HighlightKind` (byte offsets into each line).
//! Markdown fences and HTML <script>/<style> are highlighted through
//! injections, exactly as in Rust.

const std = @import("std");
const c = @import("ts_c");
const queries = @import("ts_queries");
const hl = @import("highlight.zig");
const language = @import("language.zig");
const Allocator = std.mem.Allocator;

pub const LanguageId = language.LanguageId;
pub const detectLanguage = language.detectLanguage;
pub const languageForAlias = language.languageForAlias;
pub const languageForPath = language.languageForPath;

/// Lower-level tree-sitter-highlight port (configurations + event iterator).
pub const highlighter = hl;

pub const default_max_source_bytes: usize = 1024 * 1024;
pub const default_max_spans: usize = 200_000;

pub const HighlightLimits = struct {
    max_source_bytes: usize = default_max_source_bytes,
    max_spans: usize = default_max_spans,
};

/// Syntax roles. Tag names (and order) match the theme's `SyntaxKey`
/// (apps/zeron/src/theme/model.zig), so `themeKey` maps them 1:1 onto the
/// theme's 31 syntax colors.
pub const HighlightKind = enum {
    comment,
    keyword,
    string,
    string_special,
    escape,
    number,
    boolean,
    type_name,
    type_builtin,
    constructor,
    function,
    function_builtin,
    macro_name,
    property,
    constant,
    variable,
    variable_special,
    parameter,
    operator,
    punctuation,
    tag,
    attribute,
    label,
    markup_heading,
    markup_raw,
    markup_link,
    markup_reference,
    markup_emphasis,
    markup_strong,
    embedded,
    invalid,

    /// Stable precedence used to resolve overlapping parser captures.
    pub fn precedence(self: HighlightKind) u8 {
        return switch (self) {
            .invalid => 100,
            .escape => 95,
            .macro_name => 90,
            .property, .attribute => 85,
            .function_builtin, .type_builtin, .variable_special => 80,
            .string_special, .constructor, .parameter => 75,
            .function, .type_name, .constant, .tag, .label => 70,
            .comment, .keyword, .string, .number, .boolean => 60,
            .variable, .operator => 50,
            .punctuation, .embedded => 40,
            // Markdown block captures can wrap more specific inline captures,
            // and fenced-code captures can wrap an injected language. Keep
            // markup below programming-language tokens while preserving the
            // nesting order among Markdown roles.
            .markup_heading => 30,
            .markup_emphasis => 31,
            .markup_strong => 32,
            .markup_link, .markup_reference => 33,
            .markup_raw => 34,
        };
    }

    /// Stable snake_case name (zeron's editor adapter `name_for_kind`).
    pub fn name(self: HighlightKind) []const u8 {
        return switch (self) {
            .type_name => "type",
            .macro_name => "macro",
            inline else => |k| @tagName(k),
        };
    }

    pub fn fromName(s: []const u8) ?HighlightKind {
        inline for (comptime std.enums.values(HighlightKind)) |k| {
            if (std.mem.eql(u8, s, comptime k.name())) return k;
        }
        return null;
    }

    /// The same-named member of a theme key enum (e.g. `zeron_theme`'s
    /// `HighlightKind` / `model.SyntaxKey`); fails to compile on a mismatch.
    pub fn themeKey(self: HighlightKind, comptime Key: type) Key {
        return switch (self) {
            inline else => |k| @field(Key, @tagName(k)),
        };
    }
};

/// Highlight names recognized in queries, ordered generic to specific.
/// `Configuration.configure` resolves dotted captures to the best match.
pub const capture_names = [_][]const u8{
    "comment",         "keyword",     "string",       "string.special", "string.escape",
    "number",          "boolean",     "type",         "type.builtin",   "constructor",
    "function",        "function.builtin", "function.macro", "property", "constant",
    "variable",        "variable.builtin", "variable.parameter", "operator", "punctuation",
    "tag",             "attribute",   "label",        "text.title",     "text.literal",
    "text.uri",        "text.reference", "text.emphasis", "text.strong", "embedded",
    "error",
};

/// `HighlightKind` for each entry of `capture_names`.
pub const capture_kinds = [_]HighlightKind{
    .comment,        .keyword,          .string,        .string_special,   .escape,
    .number,         .boolean,          .type_name,     .type_builtin,     .constructor,
    .function,       .function_builtin, .macro_name,    .property,         .constant,
    .variable,       .variable_special, .parameter,     .operator,         .punctuation,
    .tag,            .attribute,        .label,         .markup_heading,   .markup_raw,
    .markup_link,    .markup_reference, .markup_emphasis, .markup_strong,  .embedded,
    .invalid,
};

comptime {
    std.debug.assert(capture_names.len == capture_kinds.len);
    std.debug.assert(capture_kinds.len == std.enums.values(HighlightKind).len);
}

pub const HighlightSpan = struct {
    start: usize,
    end: usize,
    kind: HighlightKind,
};

pub const HighlightRequest = struct {
    source: []const u8,
    path: ?[]const u8 = null,
    fence_tag: ?[]const u8 = null,
};

pub const HighlightError = error{
    /// No language could be detected.
    UnknownLanguage,
    /// A span lies outside the source or has start > end.
    InvalidRange,
    /// A span does not start/end on a UTF-8 boundary.
    InvalidUtf8Boundary,
    SourceTooLarge,
    TooManySpans,
    /// A grammar's queries failed to load, or parsing failed.
    Parser,
    /// The cancellation flag was raised (Rust reports `Parser("Cancelled")`).
    Cancelled,
    GrammarUnavailable,
    OutOfMemory,
};

/// Line-relative spans; `line(i)` is sorted and non-overlapping.
pub const HighlightedDocument = struct {
    language: LanguageId,
    /// All lines' spans, concatenated.
    spans: []HighlightSpan,
    /// `line(i) == spans[line_offsets[i]..line_offsets[i + 1]]`.
    line_offsets: []u32,

    pub fn deinit(self: *HighlightedDocument, gpa: Allocator) void {
        gpa.free(self.spans);
        gpa.free(self.line_offsets);
        self.* = undefined;
    }

    pub fn lineCount(self: *const HighlightedDocument) usize {
        return self.line_offsets.len - 1;
    }

    pub fn line(self: *const HighlightedDocument, index: usize) []const HighlightSpan {
        return self.spans[self.line_offsets[index]..self.line_offsets[index + 1]];
    }

    /// Validate, split, and normalize absolute source spans into line-relative spans.
    pub fn fromAbsoluteSpans(
        gpa: Allocator,
        lang: LanguageId,
        source: []const u8,
        spans: []const HighlightSpan,
    ) HighlightError!HighlightedDocument {
        const starts = try lineStarts(gpa, source);
        defer gpa.free(starts);
        const lines = try gpa.alloc(std.ArrayList(HighlightSpan), starts.len);
        for (lines) |*l| l.* = .empty;
        defer {
            for (lines) |*l| l.deinit(gpa);
            gpa.free(lines);
        }
        for (spans) |span| {
            try validateSpan(source, span.start, span.end);
            if (span.start >= span.end) continue;
            // partition_point(start <= span.start) - 1
            var first_line: usize = 0;
            {
                var lo: usize = 0;
                var hi: usize = starts.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (starts[mid] <= span.start) lo = mid + 1 else hi = mid;
                }
                first_line = lo - 1;
            }
            var line_ix = first_line;
            while (line_ix < starts.len) : (line_ix += 1) {
                const start = starts[line_ix];
                const raw_end = if (line_ix + 1 < starts.len) starts[line_ix + 1] else source.len;
                var end = raw_end;
                if (end >= 1 and source[end - 1] == '\n') {
                    end -= 1;
                    if (end >= 1 and source[end - 1] == '\r') end -= 1;
                }
                const seg_start = @max(span.start, start);
                const seg_end = @min(span.end, end);
                if (seg_start < seg_end) {
                    try lines[line_ix].append(gpa, .{ .start = seg_start - start, .end = seg_end - start, .kind = span.kind });
                }
                if (raw_end >= span.end) break;
            }
        }

        var out: std.ArrayList(HighlightSpan) = .empty;
        errdefer out.deinit(gpa);
        const offsets = try gpa.alloc(u32, starts.len + 1);
        errdefer gpa.free(offsets);
        var scratch: NormalizeScratch = .{};
        defer scratch.deinit(gpa);
        for (lines, 0..) |l, i| {
            offsets[i] = @intCast(out.items.len);
            try normalizeLine(gpa, l.items, &out, &scratch);
        }
        offsets[starts.len] = @intCast(out.items.len);
        return .{ .language = lang, .spans = try out.toOwnedSlice(gpa), .line_offsets = offsets };
    }
};

fn isCharBoundary(s: []const u8, i: usize) bool {
    if (i == 0 or i == s.len) return true;
    if (i > s.len) return false;
    return (s[i] & 0xC0) != 0x80;
}

fn validateSpan(source: []const u8, start: usize, end: usize) HighlightError!void {
    if (start > end or end > source.len) return error.InvalidRange;
    if (!isCharBoundary(source, start) or !isCharBoundary(source, end)) return error.InvalidUtf8Boundary;
}

fn lineStarts(gpa: Allocator, source: []const u8) Allocator.Error![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);
    for (source, 0..) |ch, i| {
        if (ch == '\n' and i + 1 < source.len) try starts.append(gpa, i + 1);
    }
    return starts.toOwnedSlice(gpa);
}

const Edge = struct { offset: usize, index: usize, is_start: bool };
const ActiveKey = struct { precedence: u8, index: usize };

const NormalizeScratch = struct {
    edges: std.ArrayList(Edge) = .empty,
    active: std.ArrayList(ActiveKey) = .empty,

    fn deinit(self: *NormalizeScratch, gpa: Allocator) void {
        self.edges.deinit(gpa);
        self.active.deinit(gpa);
    }
};

fn activeLess(a: ActiveKey, b: ActiveKey) bool {
    if (a.precedence != b.precedence) return a.precedence < b.precedence;
    return a.index < b.index;
}

/// Resolve overlaps by precedence (ties: the later span wins) and merge
/// adjacent equal-kind runs. Appends the line's result to `out`.
fn normalizeLine(gpa: Allocator, spans: []const HighlightSpan, out: *std.ArrayList(HighlightSpan), scratch: *NormalizeScratch) Allocator.Error!void {
    const line_begin = out.items.len;
    const edges = &scratch.edges;
    const active = &scratch.active;
    edges.clearRetainingCapacity();
    active.clearRetainingCapacity();
    for (spans, 0..) |span, i| {
        try edges.append(gpa, .{ .offset = span.start, .index = i, .is_start = true });
        try edges.append(gpa, .{ .offset = span.end, .index = i, .is_start = false });
    }
    std.mem.sort(Edge, edges.items, {}, struct {
        fn lt(_: void, a: Edge, b: Edge) bool {
            return a.offset < b.offset;
        }
    }.lt);

    var cursor: usize = 0;
    while (cursor < edges.items.len) {
        const offset = edges.items[cursor].offset;
        const group_start = cursor;
        while (cursor < edges.items.len and edges.items[cursor].offset == offset) : (cursor += 1) {
            const e = edges.items[cursor];
            if (!e.is_start) {
                const key: ActiveKey = .{ .precedence = spans[e.index].kind.precedence(), .index = e.index };
                for (active.items, 0..) |k, j| {
                    if (k.precedence == key.precedence and k.index == key.index) {
                        _ = active.orderedRemove(j);
                        break;
                    }
                }
            }
        }
        for (edges.items[group_start..cursor]) |e| {
            if (e.is_start) {
                const key: ActiveKey = .{ .precedence = spans[e.index].kind.precedence(), .index = e.index };
                var pos: usize = active.items.len;
                while (pos > 0 and activeLess(key, active.items[pos - 1])) pos -= 1;
                if (pos < active.items.len and active.items[pos].precedence == key.precedence and active.items[pos].index == key.index) continue;
                try active.insert(gpa, pos, key);
            }
        }
        if (cursor >= edges.items.len) break;
        const next_offset = edges.items[cursor].offset;
        if (offset == next_offset) continue;
        if (active.items.len > 0) {
            const kind = spans[active.items[active.items.len - 1].index].kind;
            if (out.items.len > line_begin) {
                const prev = &out.items[out.items.len - 1];
                if (prev.kind == kind and prev.end == offset) {
                    prev.end = next_offset;
                    continue;
                }
            }
            try out.append(gpa, .{ .start = offset, .end = next_offset, .kind = kind });
        }
    }
}

/// Whether this build contains a parser and compatible highlight queries.
pub fn supportsLanguage(lang: LanguageId) bool {
    _ = lang;
    return true;
}

/// Languages a parent may inject (applies to the whole injection tree).
fn injectedLanguages(parent: LanguageId) []const LanguageId {
    return switch (parent) {
        .html => &.{ .javascript, .css, .json },
        .markdown => &.{
            .rust, .javascript, .jsx,  .typescript, .tsx,  .python, .go,   .json,       .jsonc,
            .bash, .toml,       .html, .css,        .yaml, .c,      .cpp,  .csharp,     .java,
            .kotlin, .swift,    .ruby, .php,        .sql,  .lua,    .dockerfile, .nix, .make,
        },
        .dockerfile => &.{ .bash, .json, .yaml, .toml },
        else => &.{},
    };
}

extern fn tree_sitter_rust() *const c.TSLanguage;
extern fn tree_sitter_javascript() *const c.TSLanguage;
extern fn tree_sitter_typescript() *const c.TSLanguage;
extern fn tree_sitter_tsx() *const c.TSLanguage;
extern fn tree_sitter_python() *const c.TSLanguage;
extern fn tree_sitter_go() *const c.TSLanguage;
extern fn tree_sitter_json() *const c.TSLanguage;
extern fn tree_sitter_bash() *const c.TSLanguage;
extern fn tree_sitter_toml() *const c.TSLanguage;
extern fn tree_sitter_markdown() *const c.TSLanguage;
extern fn tree_sitter_markdown_inline() *const c.TSLanguage;
extern fn tree_sitter_html() *const c.TSLanguage;
extern fn tree_sitter_css() *const c.TSLanguage;
extern fn tree_sitter_yaml() *const c.TSLanguage;
extern fn tree_sitter_c() *const c.TSLanguage;
extern fn tree_sitter_cpp() *const c.TSLanguage;
extern fn tree_sitter_c_sharp() *const c.TSLanguage;
extern fn tree_sitter_java() *const c.TSLanguage;
extern fn tree_sitter_kotlin() *const c.TSLanguage;
extern fn tree_sitter_swift() *const c.TSLanguage;
extern fn tree_sitter_ruby() *const c.TSLanguage;
extern fn tree_sitter_php() *const c.TSLanguage;
extern fn tree_sitter_sql() *const c.TSLanguage;
extern fn tree_sitter_lua() *const c.TSLanguage;
extern fn tree_sitter_nix() *const c.TSLanguage;
extern fn tree_sitter_make() *const c.TSLanguage;
extern fn tree_sitter_containerfile() *const c.TSLanguage;

const kotlin_highlights = @embedFile("queries/kotlin/highlights.scm");

const ConfigSpec = struct {
    language: *const c.TSLanguage,
    name: []const u8,
    highlights: []const []const u8,
    injections: []const u8 = "",
    locals: []const u8 = "",
};

/// Configuration slot: one per `LanguageId`, plus Markdown's inline grammar.
const Slot = union(enum) {
    lang: LanguageId,
    markdown_inline,

    fn index(self: Slot) usize {
        return switch (self) {
            .lang => |l| @intFromEnum(l),
            .markdown_inline => slot_count - 1,
        };
    }
};
const slot_count = std.enums.values(LanguageId).len + 1;

fn spec(slot: Slot) ConfigSpec {
    const q = queries;
    return switch (slot) {
        .markdown_inline => .{
            .language = tree_sitter_markdown_inline(),
            .name = "markdown_inline",
            .highlights = &.{q.markdown_inline_highlights},
            .injections = q.markdown_inline_injections,
        },
        .lang => |l| switch (l) {
            .rust => .{ .language = tree_sitter_rust(), .name = "rust", .highlights = &.{q.rust_highlights}, .injections = q.rust_injections },
            .javascript => .{ .language = tree_sitter_javascript(), .name = "javascript", .highlights = &.{q.javascript_highlights}, .injections = q.javascript_injections, .locals = q.javascript_locals },
            .jsx => .{ .language = tree_sitter_javascript(), .name = "jsx", .highlights = &.{ q.javascript_highlights, q.javascript_jsx_highlights }, .injections = q.javascript_injections, .locals = q.javascript_locals },
            .typescript => .{ .language = tree_sitter_typescript(), .name = "typescript", .highlights = &.{ q.javascript_highlights, q.typescript_highlights }, .locals = q.typescript_locals },
            .tsx => .{ .language = tree_sitter_tsx(), .name = "tsx", .highlights = &.{ q.javascript_highlights, q.javascript_jsx_highlights, q.typescript_highlights }, .locals = q.typescript_locals },
            .python => .{ .language = tree_sitter_python(), .name = "python", .highlights = &.{q.python_highlights} },
            .go => .{ .language = tree_sitter_go(), .name = "go", .highlights = &.{q.go_highlights} },
            .json, .jsonc => .{ .language = tree_sitter_json(), .name = "json", .highlights = &.{q.json_highlights} },
            .bash => .{ .language = tree_sitter_bash(), .name = "bash", .highlights = &.{q.bash_highlights} },
            .toml => .{ .language = tree_sitter_toml(), .name = "toml", .highlights = &.{q.toml_highlights} },
            .markdown => .{ .language = tree_sitter_markdown(), .name = "markdown", .highlights = &.{q.markdown_block_highlights}, .injections = q.markdown_block_injections },
            .html => .{ .language = tree_sitter_html(), .name = "html", .highlights = &.{q.html_highlights}, .injections = q.html_injections },
            .css => .{ .language = tree_sitter_css(), .name = "css", .highlights = &.{q.css_highlights} },
            .yaml => .{ .language = tree_sitter_yaml(), .name = "yaml", .highlights = &.{q.yaml_highlights} },
            .c => .{ .language = tree_sitter_c(), .name = "c", .highlights = &.{q.c_highlights} },
            .cpp => .{ .language = tree_sitter_cpp(), .name = "cpp", .highlights = &.{ q.c_highlights, q.cpp_highlights } },
            .csharp => .{ .language = tree_sitter_c_sharp(), .name = "csharp", .highlights = &.{q.csharp_highlights} },
            .java => .{ .language = tree_sitter_java(), .name = "java", .highlights = &.{q.java_highlights} },
            .kotlin => .{ .language = tree_sitter_kotlin(), .name = "kotlin", .highlights = &.{kotlin_highlights} },
            .swift => .{ .language = tree_sitter_swift(), .name = "swift", .highlights = &.{q.swift_highlights}, .locals = q.swift_locals },
            .ruby => .{ .language = tree_sitter_ruby(), .name = "ruby", .highlights = &.{q.ruby_highlights}, .locals = q.ruby_locals },
            .php => .{ .language = tree_sitter_php(), .name = "php", .highlights = &.{q.php_highlights} },
            .sql => .{ .language = tree_sitter_sql(), .name = "sql", .highlights = &.{q.sql_highlights} },
            .lua => .{ .language = tree_sitter_lua(), .name = "lua", .highlights = &.{q.lua_highlights}, .locals = q.lua_locals },
            .nix => .{ .language = tree_sitter_nix(), .name = "nix", .highlights = &.{q.nix_highlights} },
            .make => .{ .language = tree_sitter_make(), .name = "make", .highlights = &.{q.make_highlights} },
            .dockerfile => .{ .language = tree_sitter_containerfile(), .name = "dockerfile", .highlights = &.{q.containerfile_highlights}, .injections = q.containerfile_injections },
        },
    };
}

/// Build (but do not cache) the configuration for `slot`, with zeron's query
/// adjustments applied and `capture_names` configured.
fn buildConfiguration(gpa: Allocator, slot: Slot) hl.Error!hl.Configuration {
    const s = spec(slot);
    var highlights = try std.mem.join(gpa, "\n", s.highlights);
    defer gpa.free(highlights);
    var injections: []u8 = try gpa.dupe(u8, s.injections);
    defer gpa.free(injections);

    switch (slot) {
        // The upstream Rust query groups numbers and booleans as
        // `constant.builtin`. Zeron preserves those structural roles separately.
        .lang => |l| if (l == .rust) {
            for ([_][2][]const u8{
                .{ "(boolean_literal) @constant.builtin", "(boolean_literal) @boolean" },
                .{ "(integer_literal) @constant.builtin", "(integer_literal) @number" },
                .{ "(float_literal) @constant.builtin", "(float_literal) @number" },
            }) |r| {
                const next = try std.mem.replaceOwned(u8, gpa, highlights, r[0], r[1]);
                gpa.free(highlights);
                highlights = next;
            }
        } else if (l == .markdown) {
            // tree-sitter-highlight excludes child ranges from injections by
            // default. The Markdown block grammar's `inline` node owns
            // anonymous children that cover its source, so the upstream query
            // otherwise injects an empty range.
            const next = try std.mem.replaceOwned(
                u8,
                gpa,
                injections,
                "((inline) @injection.content\n  (#set! injection.language \"markdown_inline\"))",
                "((inline) @injection.content\n  (#set! injection.language \"markdown_inline\")\n  (#set! injection.include-children))",
            );
            gpa.free(injections);
            injections = next;
        },
        .markdown_inline => {},
    }

    var config = try hl.Configuration.init(gpa, s.language, s.name, highlights, injections, s.locals);
    config.configure(&capture_names);
    return config;
}

/// Lazily compiled, immutable per-grammar configurations. Thread-safe: each
/// grammar compiles once; unrelated grammars never wait on each other.
pub const Registry = struct {
    gpa: Allocator,
    slots: [slot_count]Entry = @splat(.{}),

    const State = enum(u8) { empty, building, ready, failed };
    const Entry = struct {
        state: std.atomic.Value(State) = .init(.empty),
        config: hl.Configuration = undefined,
    };

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (&self.slots) |*e| {
            if (e.state.load(.acquire) == .ready) e.config.deinit();
            e.state.store(.empty, .release);
        }
    }

    fn get(self: *Registry, slot: Slot) HighlightError!*const hl.Configuration {
        const e = &self.slots[slot.index()];
        while (true) {
            switch (e.state.load(.acquire)) {
                .ready => return &e.config,
                .failed => return error.Parser,
                .building => std.atomic.spinLoopHint(),
                .empty => if (e.state.cmpxchgWeak(.empty, .building, .acquire, .monotonic) == null) {
                    e.config = buildConfiguration(self.gpa, slot) catch |err| {
                        // Query errors are permanent (as Rust's OnceLock<Result>);
                        // allocation failures may succeed later.
                        if (err == error.OutOfMemory) {
                            e.state.store(.empty, .release);
                            return error.OutOfMemory;
                        }
                        e.state.store(.failed, .release);
                        return error.Parser;
                    };
                    e.state.store(.ready, .release);
                    return &e.config;
                },
            }
        }
    }

    /// The compiled configuration for `lang` (compiling it on first use).
    pub fn configuration(self: *Registry, lang: LanguageId) HighlightError!*const hl.Configuration {
        return self.get(.{ .lang = lang });
    }

    pub fn highlight(self: *Registry, gpa: Allocator, request: HighlightRequest) HighlightError!HighlightedDocument {
        return self.highlightWithLimits(gpa, request, .{}, null);
    }

    /// Highlight a complete document with explicit limits and cooperative cancellation.
    pub fn highlightWithLimits(
        self: *Registry,
        gpa: Allocator,
        request: HighlightRequest,
        limits: HighlightLimits,
        cancellation_flag: ?*const std.atomic.Value(usize),
    ) HighlightError!HighlightedDocument {
        if (request.source.len > limits.max_source_bytes) return error.SourceTooLarge;
        const first_line: ?[]const u8 = if (request.source.len == 0) null else blk: {
            var l = request.source[0 .. std.mem.indexOfScalar(u8, request.source, '\n') orelse request.source.len];
            if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
            break :blk l;
        };
        const lang = detectLanguage(request.path, request.fence_tag, first_line) orelse return error.UnknownLanguage;
        if (!supportsLanguage(lang)) return error.GrammarUnavailable;

        const primary = try self.configuration(lang);
        var ctx: InjectionContext = .{
            .registry = self,
            .injected = injectedLanguages(lang),
            .markdown_inline = if (lang == .markdown) try self.get(.markdown_inline) else null,
        };

        var h = hl.Highlighter.init(gpa) catch return error.OutOfMemory;
        defer h.deinit();
        var events = h.highlight(primary, request.source, cancellation_flag, .{
            .context = &ctx,
            .resolve = InjectionContext.resolve,
        }) catch |err| return mapError(err);
        defer events.deinit();

        var active: std.ArrayList(HighlightKind) = .empty;
        defer active.deinit(gpa);
        var spans: std.ArrayList(HighlightSpan) = .empty;
        defer spans.deinit(gpa);
        while (events.next() catch |err| return mapError(err)) |event| switch (event) {
            .highlight_start => |i| try active.append(gpa, capture_kinds[i]),
            .highlight_end => _ = active.pop(),
            .source => |s| {
                // `max_by_key`: the last of the highest-precedence kinds wins.
                if (active.items.len > 0) {
                    var best = active.items[0];
                    for (active.items[1..]) |k| {
                        if (k.precedence() >= best.precedence()) best = k;
                    }
                    try spans.append(gpa, .{ .start = s.start, .end = s.end, .kind = best });
                    if (spans.items.len > limits.max_spans) return error.TooManySpans;
                }
            },
        };
        return HighlightedDocument.fromAbsoluteSpans(gpa, lang, request.source, spans.items);
    }
};

fn mapError(err: hl.Error) HighlightError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.InvalidLanguage, error.InvalidQuery => error.Parser,
    };
}

const InjectionContext = struct {
    registry: *Registry,
    injected: []const LanguageId,
    markdown_inline: ?*const hl.Configuration,

    fn resolve(context: *anyopaque, name: []const u8) ?*const hl.Configuration {
        const self: *InjectionContext = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, "markdown_inline")) return self.markdown_inline;
        const lang = languageForAlias(name) orelse return null;
        if (std.mem.indexOfScalar(LanguageId, self.injected, lang) == null) return null;
        return self.registry.configuration(lang) catch null;
    }
};

/// Process-wide registry used by `highlight` / `highlightWithLimits`
/// (compiled queries live for the life of the process, like Rust's statics).
var global_registry: Registry = .{ .gpa = std.heap.smp_allocator };

pub fn globalRegistry() *Registry {
    return &global_registry;
}

/// Highlight a complete document with the default resource limits.
/// The result is allocated with `gpa`; free it with `deinit(gpa)`.
pub fn highlight(gpa: Allocator, request: HighlightRequest) HighlightError!HighlightedDocument {
    return global_registry.highlight(gpa, request);
}

pub fn highlightWithLimits(
    gpa: Allocator,
    request: HighlightRequest,
    limits: HighlightLimits,
    cancellation_flag: ?*const std.atomic.Value(usize),
) HighlightError!HighlightedDocument {
    return global_registry.highlightWithLimits(gpa, request, limits, cancellation_flag);
}

test {
    _ = @import("regex.zig");
    _ = @import("language.zig");
    _ = @import("root_test.zig");
    _ = @import("parity_test.zig");
}
