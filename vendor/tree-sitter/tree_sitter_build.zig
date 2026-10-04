//! Build helpers for the vendored tree-sitter runtime and grammars, imported by
//! the repo's build.zig. Everything is plain C11 (no grammar ships a C++
//! scanner), so no libc++ is needed.
//!
//! - `tree-sitter`: the runtime amalgamation (`runtime/src/lib.c`).
//! - `tree-sitter-grammars`: the grammars' parser.c / scanner.c in one
//!   static library (each exports `tree_sitter_<lang>()`), plus a small
//!   library per grammar that needs its own include path.
//! - `ts_c`: translate-c of `runtime/include/tree_sitter/api.h`.
//! - `ts_queries`: `queries.zig`, which @embedFiles the vendored .scm queries.

const std = @import("std");

const root = "vendor/tree-sitter/";

/// Grammar C sources relative to `vendor/tree-sitter/grammars/` whose
/// includes all resolve relative to the including file.
const grammar_sources = [_][]const u8{
    "bash/src/parser.c",
    "bash/src/scanner.c",
    "c/src/parser.c",
    "c-sharp/src/parser.c",
    "c-sharp/src/scanner.c",
    "containerfile/src/parser.c",
    "containerfile/src/scanner.c",
    "cpp/src/parser.c",
    "cpp/src/scanner.c",
    "css/src/parser.c",
    "css/src/scanner.c",
    "go/src/parser.c",
    "html/src/parser.c",
    "html/src/scanner.c",
    "java/src/parser.c",
    "javascript/src/parser.c",
    "javascript/src/scanner.c",
    "json/src/parser.c",
    "kotlin/src/parser.c",
    "kotlin/src/scanner.c",
    "lua/src/parser.c",
    "lua/src/scanner.c",
    "make/src/parser.c",
    "markdown/tree-sitter-markdown/src/parser.c",
    "markdown/tree-sitter-markdown/src/scanner.c",
    "markdown/tree-sitter-markdown-inline/src/parser.c",
    "markdown/tree-sitter-markdown-inline/src/scanner.c",
    "python/src/parser.c",
    "python/src/scanner.c",
    "ruby/src/parser.c",
    "ruby/src/scanner.c",
    "rust/src/parser.c",
    "rust/src/scanner.c",
    "sql/src/parser.c",
    "sql/src/scanner.c",
    "swift/src/parser.c",
    "swift/src/scanner.c",
    "toml/src/parser.c",
    "toml/src/scanner.c",
    "yaml/src/parser.c",
    "yaml/src/scanner.c",
};

/// Grammars whose scanners need their own `src/` on the include path (a
/// shared header in `common/`, or `<tree_sitter/parser.h>`). Each gets its
/// own small library so grammars never see another's tree_sitter headers.
const include_groups = [_]struct { name: []const u8, include: []const u8, files: []const []const u8 }{
    .{ .name = "nix", .include = "nix/src", .files = &.{ "nix/src/parser.c", "nix/src/scanner.c" } },
    .{ .name = "php", .include = "php/php/src", .files = &.{ "php/php/src/parser.c", "php/php/src/scanner.c" } },
    .{ .name = "typescript", .include = "typescript/typescript/src", .files = &.{ "typescript/typescript/src/parser.c", "typescript/typescript/src/scanner.c" } },
    .{ .name = "tsx", .include = "typescript/tsx/src", .files = &.{ "typescript/tsx/src/parser.c", "typescript/tsx/src/scanner.c" } },
};

const common_flags = [_][]const u8{
    "-std=c11",
    // Generated parsers and the runtime are not UBSan-clean in Debug.
    "-fno-sanitize=undefined",
    "-Wno-unused-parameter",
    "-Wno-unused-but-set-variable",
    "-Wno-unused-value",
    "-Wno-implicit-fallthrough",
    "-Wno-sign-compare",
    "-Wno-trigraphs",
    "-Wno-incompatible-pointer-types",
};

pub const TreeSitter = struct {
    runtime: *std.Build.Step.Compile,
    grammars: *std.Build.Step.Compile,
    grammar_groups: [include_groups.len]*std.Build.Step.Compile,
    /// translate-c of tree_sitter/api.h
    c: *std.Build.Module,
    /// Embedded highlight/injection/locals queries.
    queries: *std.Build.Module,

    /// Link both libraries into `m` and expose `ts_c` / `ts_queries` imports.
    pub fn addTo(self: TreeSitter, m: *std.Build.Module) void {
        m.linkLibrary(self.runtime);
        m.linkLibrary(self.grammars);
        for (self.grammar_groups) |lib| m.linkLibrary(lib);
        m.addImport("ts_c", self.c);
        m.addImport("ts_queries", self.queries);
    }
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) TreeSitter {
    // Parsing speed matters even in Debug test runs, and the C sources are
    // upstream code we do not debug: build them optimized unless asked for
    // a smaller release.
    const c_optimize: std.builtin.OptimizeMode = if (optimize == .debug) .fast else optimize;

    const runtime = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = c_optimize, .link_libc = true }),
    });
    runtime.root_module.addIncludePath(b.path(root ++ "runtime/include"));
    runtime.root_module.addIncludePath(b.path(root ++ "runtime/src"));
    runtime.root_module.addCSourceFiles(.{
        .root = b.path(root ++ "runtime/src"),
        .files = &.{"lib.c"},
        .flags = &(common_flags ++ [_][]const u8{
            "-D_POSIX_C_SOURCE=200112L",
            "-D_DEFAULT_SOURCE",
            "-D_BSD_SOURCE",
            "-D_DARWIN_C_SOURCE",
        }),
    });

    const grammars = b.addLibrary(.{
        .name = "tree-sitter-grammars",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = c_optimize, .link_libc = true }),
    });
    grammars.root_module.addCSourceFiles(.{
        .root = b.path(root ++ "grammars"),
        .files = &grammar_sources,
        .flags = &common_flags,
    });

    var groups: [include_groups.len]*std.Build.Step.Compile = undefined;
    for (include_groups, &groups) |g, *lib| {
        lib.* = b.addLibrary(.{
            .name = b.fmt("tree-sitter-{s}", .{g.name}),
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = c_optimize, .link_libc = true }),
        });
        lib.*.root_module.addIncludePath(b.path(b.fmt(root ++ "grammars/{s}", .{g.include})));
        lib.*.root_module.addCSourceFiles(.{ .root = b.path(root ++ "grammars"), .files = g.files, .flags = &common_flags });
    }

    const tc = b.addTranslateC(.{
        .root_source_file = b.path(root ++ "runtime/include/tree_sitter/api.h"),
        .target = target,
        .optimize = optimize,
    });

    const queries = b.createModule(.{
        .root_source_file = b.path(root ++ "queries.zig"),
        .target = target,
        .optimize = optimize,
    });

    return .{ .runtime = runtime, .grammars = grammars, .grammar_groups = groups, .c = tc.createModule(), .queries = queries };
}
