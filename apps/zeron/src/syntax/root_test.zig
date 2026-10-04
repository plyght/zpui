//! Ports of crates/syntax's unit tests (src/lib.rs) to the Zig API.

const std = @import("std");
const syntax = @import("root.zig");
const testing = std.testing;
const K = syntax.HighlightKind;
const Span = syntax.HighlightSpan;

fn doc(source: []const u8, path: ?[]const u8, fence: ?[]const u8) !syntax.HighlightedDocument {
    return syntax.highlight(testing.allocator, .{ .source = source, .path = path, .fence_tag = fence });
}

fn lineText(source: []const u8, index: usize) []const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) if (i == index) return std.mem.trimEnd(u8, l, "\r");
    unreachable;
}

fn hasFragment(d: *const syntax.HighlightedDocument, source: []const u8, text: []const u8, kind: K) bool {
    for (0..d.lineCount()) |li| {
        const l = lineText(source, li);
        for (d.line(li)) |s| {
            if (s.kind == kind and std.mem.eql(u8, l[s.start..s.end], text)) return true;
        }
    }
    return false;
}

fn anyKind(spans: []const Span, kind: K) bool {
    for (spans) |s| if (s.kind == kind) return true;
    return false;
}

test "spans are valid, sorted, non-overlapping and line relative" {
    const source = "let café = \"x\";\nnext";
    var d = try syntax.HighlightedDocument.fromAbsoluteSpans(testing.allocator, .rust, source, &.{
        .{ .start = 0, .end = 9, .kind = .variable },
        .{ .start = 0, .end = 3, .kind = .keyword },
        .{ .start = 12, .end = 15, .kind = .string },
        .{ .start = 17, .end = 21, .kind = .function },
    });
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.lineCount());
    try testing.expectEqual(Span{ .start = 0, .end = 3, .kind = .keyword }, d.line(0)[0]);
    for (0..d.lineCount()) |i| {
        const l = d.line(i);
        if (l.len > 1) for (l[0 .. l.len - 1], l[1..]) |a, b| try testing.expect(a.end <= b.start);
    }
    try testing.expectError(error.InvalidUtf8Boundary, syntax.HighlightedDocument.fromAbsoluteSpans(
        testing.allocator,
        .rust,
        source,
        &.{.{ .start = 8, .end = 9, .kind = .type_name }},
    ));
}

test "normalization preserves overlap precedence and tie order" {
    var d = try syntax.HighlightedDocument.fromAbsoluteSpans(testing.allocator, .rust, "0123456789", &.{
        .{ .start = 0, .end = 10, .kind = .variable },
        .{ .start = 2, .end = 8, .kind = .keyword },
        .{ .start = 4, .end = 6, .kind = .string },
    });
    defer d.deinit(testing.allocator);
    try testing.expectEqualSlices(Span, &.{
        .{ .start = 0, .end = 2, .kind = .variable },
        .{ .start = 2, .end = 4, .kind = .keyword },
        .{ .start = 4, .end = 6, .kind = .string },
        .{ .start = 6, .end = 8, .kind = .keyword },
        .{ .start = 8, .end = 10, .kind = .variable },
    }, d.line(0));
}

test "minified lines normalize without quadratic rescans" {
    const unit = "let value=1;";
    const source = try testing.allocator.alloc(u8, unit.len * 8000);
    defer testing.allocator.free(source);
    for (0..8000) |i| @memcpy(source[i * unit.len ..][0..unit.len], unit);
    var d = try doc(source, "bundle.js", null);
    defer d.deinit(testing.allocator);
    try testing.expect(d.line(0).len > 20_000);
}

test "rust highlighting distinguishes structural categories" {
    const source =
        \\pub struct Widget { field: usize }
        \\fn build(value: usize) -> Widget {
        \\    let name = format!("item-{value}");
        \\    Widget { field: 42 }
        \\}
    ;
    var d = try doc(source, "src/lib.rs", null);
    defer d.deinit(testing.allocator);
    try testing.expect(hasFragment(&d, source, "pub", .keyword));
    try testing.expect(hasFragment(&d, source, "Widget", .type_name));
    try testing.expect(hasFragment(&d, source, "build", .function));
    try testing.expect(hasFragment(&d, source, "format!", .macro_name));
    try testing.expect(hasFragment(&d, source, "42", .number));
}

test "rust multiline raw, unicode and incomplete code remain valid" {
    const source = "/* café\ncomment */\nlet raw = r#\"héllo\nworld\"#;\nlet before = 7;\nfn incomplete( {";
    var d = try doc(source, null, "rust");
    defer d.deinit(testing.allocator);
    try testing.expect(anyKind(d.line(1), .comment));
    try testing.expect(anyKind(d.line(3), .string));
    try testing.expect(anyKind(d.spans, .number));
    for (0..d.lineCount()) |li| {
        const l = lineText(source, li);
        for (d.line(li)) |s| {
            try testing.expect(s.end <= l.len);
            try testing.expect(s.start == l.len or l[s.start] & 0xC0 != 0x80);
            try testing.expect(s.end == l.len or l[s.end] & 0xC0 != 0x80);
        }
    }
}

test "limits and unknown languages degrade with typed errors" {
    try testing.expectError(error.SourceTooLarge, syntax.highlightWithLimits(
        testing.allocator,
        .{ .source = "fn main() {}", .path = "main.rs" },
        .{ .max_source_bytes = 2, .max_spans = 10 },
        null,
    ));
    try testing.expectError(error.TooManySpans, syntax.highlightWithLimits(
        testing.allocator,
        .{ .source = "fn main() { let a = 1; }", .path = "main.rs" },
        .{ .max_spans = 2 },
        null,
    ));
    try testing.expectError(error.UnknownLanguage, doc("plain", "unknown.extension", null));
}

test "cancellation stops highlighting" {
    // Like Rust, the flag is polled periodically (parser progress callback,
    // every 100 highlight events), so use a document big enough to poll.
    const unit = "fn main() { let value = 1; }\n";
    const source = try testing.allocator.alloc(u8, unit.len * 2000);
    defer testing.allocator.free(source);
    for (0..2000) |i| @memcpy(source[i * unit.len ..][0..unit.len], unit);
    var flag: std.atomic.Value(usize) = .init(1);
    try testing.expectError(error.Cancelled, syntax.highlightWithLimits(
        testing.allocator,
        .{ .source = source, .path = "main.rs" },
        .{},
        &flag,
    ));
}

test "every registered grammar and query loads" {
    const fixtures = [_]struct { syntax.LanguageId, []const u8, []const u8 }{
        .{ .rust, "lib.rs", "fn main() {}" },
        .{ .javascript, "app.js", "const value = call(42);" },
        .{ .jsx, "app.jsx", "const view = <main id=\"x\" />;" },
        .{ .typescript, "app.ts", "const value: number = 42;" },
        .{ .tsx, "app.tsx", "const view: JSX.Element = <main />;" },
        .{ .python, "app.py", "def call(value):\n    return value" },
        .{ .go, "main.go", "package main\nfunc main() {}" },
        .{ .json, "a.json", "{\"value\": 42}" },
        .{ .jsonc, "a.jsonc", "{\"value\": 42}" },
        .{ .bash, "run.sh", "echo \"hello\"" },
        .{ .toml, "Cargo.toml", "name = \"zeron\"" },
        .{ .markdown, "README.md", "# Heading\n\n`code`" },
        .{ .html, "index.html", "<main id=\"app\"></main>" },
        .{ .css, "app.css", ".app { color: red; }" },
        .{ .yaml, "app.yml", "name: zeron" },
        .{ .c, "main.c", "int main(void) { return 0; }" },
        .{ .cpp, "main.cpp", "int main() { return 0; }" },
        .{ .csharp, "App.cs", "class App { int Value = 1; }" },
        .{ .java, "App.java", "class App { int value = 1; }" },
        .{ .kotlin, "App.kt", "val value = 1" },
        .{ .swift, "App.swift", "let value: Int = 1" },
        .{ .ruby, "app.rb", "def call(value)\n value\nend" },
        .{ .php, "app.php", "<?php function call() { return 1; }" },
        .{ .sql, "query.sql", "SELECT name FROM users;" },
        .{ .lua, "app.lua", "local value = 1" },
        .{ .nix, "flake.nix", "{ pkgs }: pkgs.hello" },
        .{ .make, "Makefile", "all:\n\techo hello" },
        .{ .dockerfile, "Dockerfile", "FROM alpine\nRUN echo hello" },
    };
    try testing.expectEqual(std.enums.values(syntax.LanguageId).len, fixtures.len);
    for (fixtures) |f| {
        const config = try syntax.globalRegistry().configuration(f[0]);
        try testing.expect(config.names().len > 0);
        var d = try doc(f[2], f[1], null);
        defer d.deinit(testing.allocator);
        try testing.expectEqual(f[0], d.language);
        try testing.expect(d.spans.len > 0);
    }
}

test "html injects javascript and css" {
    const source =
        \\<main id="app">
        \\<style>.item { color: red; }</style>
        \\<script>const answer = call(42);</script>
        \\</main>
    ;
    var d = try doc(source, "index.html", null);
    defer d.deinit(testing.allocator);
    for ([_]K{ .tag, .attribute, .keyword, .number }) |k| try testing.expect(anyKind(d.spans, k));
}

test "jsonc accepts and highlights comments" {
    const source = "{\n  // explanation\n  \"enabled\": true\n}\n";
    var d = try doc(source, "settings.jsonc", null);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(syntax.LanguageId.jsonc, d.language);
    try testing.expect(anyKind(d.line(1), .comment));
}

test "unknown markdown fence does not break parent highlighting" {
    var d = try doc("# Title\n\n```unknown-language\nopaque\n```\n", "README.md", null);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(syntax.LanguageId.markdown, d.language);
}

test "markdown highlights block and inline semantics" {
    const source = "# Heading with *emphasis* and **strong**\n\nUse `inline code` and [reference](https://example.com).\n";
    var d = try doc(source, "README.md", null);
    defer d.deinit(testing.allocator);
    const Case = struct { usize, []const u8, K };
    for ([_]Case{
        .{ 0, "Heading", .markup_heading },
        .{ 0, "emphasis", .markup_emphasis },
        .{ 0, "strong", .markup_strong },
        .{ 2, "inline code", .markup_raw },
        .{ 2, "reference", .markup_reference },
        .{ 2, "https://example.com", .markup_link },
    }) |case| {
        const l = lineText(source, case[0]);
        const start = std.mem.indexOf(u8, l, case[1]).?;
        const end = start + case[1].len;
        var found = false;
        for (d.line(case[0])) |s| {
            if (s.kind == case[2] and s.start <= start and s.end >= end) found = true;
        }
        try testing.expect(found);
    }
}

test "markdown fences use bundled child grammars" {
    const source = "```rust\nfn main() { let value = 42; }\n```\n\n```yaml\nenabled: true\n```\n";
    var d = try doc(source, "README.md", null);
    defer d.deinit(testing.allocator);
    try testing.expect(anyKind(d.line(1), .keyword));
    try testing.expect(anyKind(d.line(5), .property) or anyKind(d.line(5), .boolean) or anyKind(d.line(5), .string));
}

test "compiled queries are shared across threads" {
    const config = try syntax.globalRegistry().configuration(.rust);
    const Worker = struct {
        fn run(i: usize, expected: *const anyopaque, ok: *std.atomic.Value(usize)) void {
            const shared = syntax.globalRegistry().configuration(.rust) catch return;
            if (@as(*const anyopaque, shared) != expected) return;
            var buf: [64]u8 = undefined;
            const source = std.fmt.bufPrint(&buf, "fn example_{d}() {{ let value = {d}; }}", .{ i, i }) catch return;
            var d = syntax.highlight(std.heap.smp_allocator, .{ .source = source, .fence_tag = "rust" }) catch return;
            defer d.deinit(std.heap.smp_allocator);
            if (d.language == .rust and d.spans.len > 0) _ = ok.fetchAdd(1, .monotonic);
        }
    };
    var ok: std.atomic.Value(usize) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ i, config, &ok });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 8), ok.load(.monotonic));
}

test "kind names round-trip and map onto theme keys" {
    for (std.enums.values(K)) |k| try testing.expectEqual(@as(?K, k), K.fromName(k.name()));
    try testing.expectEqualStrings("type", K.type_name.name());
    const Mirror = enum { comment, keyword, string, string_special, escape, number, boolean, type_name, type_builtin, constructor, function, function_builtin, macro_name, property, constant, variable, variable_special, parameter, operator, punctuation, tag, attribute, label, markup_heading, markup_raw, markup_link, markup_reference, markup_emphasis, markup_strong, embedded, invalid };
    try testing.expectEqual(Mirror.macro_name, K.macro_name.themeKey(Mirror));
}
