//! Language identification (zeron_syntax `LanguageId`, `detect_language`,
//! `language_for_alias`, `language_for_path`, shebang sniffing).

const std = @import("std");

pub const LanguageId = enum {
    rust,
    javascript,
    jsx,
    typescript,
    tsx,
    python,
    go,
    json,
    jsonc,
    bash,
    toml,
    markdown,
    html,
    css,
    yaml,
    c,
    cpp,
    csharp,
    java,
    kotlin,
    swift,
    ruby,
    php,
    sql,
    lua,
    dockerfile,
    nix,
    make,

    /// The Rust enum variant name (`format!("{:?}", language)`).
    pub fn debugName(self: LanguageId) []const u8 {
        return switch (self) {
            .rust => "Rust",
            .javascript => "JavaScript",
            .jsx => "Jsx",
            .typescript => "TypeScript",
            .tsx => "Tsx",
            .python => "Python",
            .go => "Go",
            .json => "Json",
            .jsonc => "Jsonc",
            .bash => "Bash",
            .toml => "Toml",
            .markdown => "Markdown",
            .html => "Html",
            .css => "Css",
            .yaml => "Yaml",
            .c => "C",
            .cpp => "Cpp",
            .csharp => "CSharp",
            .java => "Java",
            .kotlin => "Kotlin",
            .swift => "Swift",
            .ruby => "Ruby",
            .php => "Php",
            .sql => "Sql",
            .lua => "Lua",
            .dockerfile => "Dockerfile",
            .nix => "Nix",
            .make => "Make",
        };
    }
};

/// Fence tag first, then path, then a shebang on the first line.
pub fn detectLanguage(path: ?[]const u8, fence_tag: ?[]const u8, first_line: ?[]const u8) ?LanguageId {
    if (fence_tag) |tag| if (languageForAlias(tag)) |l| return l;
    if (path) |p| if (languageForPath(p)) |l| return l;
    if (first_line) |line| if (languageForShebang(line)) |l| return l;
    return null;
}

const alias_table = [_]struct { []const u8, LanguageId }{
    .{ "rust", .rust },             .{ "rs", .rust },
    .{ "javascript", .javascript }, .{ "js", .javascript },
    .{ "mjs", .javascript },        .{ "cjs", .javascript },
    .{ "jsx", .jsx },               .{ "typescript", .typescript },
    .{ "ts", .typescript },         .{ "mts", .typescript },
    .{ "cts", .typescript },        .{ "tsx", .tsx },
    .{ "python", .python },         .{ "py", .python },
    .{ "python3", .python },        .{ "go", .go },
    .{ "golang", .go },             .{ "json", .json },
    .{ "jsonc", .jsonc },           .{ "bash", .bash },
    .{ "sh", .bash },               .{ "shell", .bash },
    .{ "zsh", .bash },              .{ "console", .bash },
    .{ "toml", .toml },             .{ "markdown", .markdown },
    .{ "md", .markdown },           .{ "html", .html },
    .{ "htm", .html },              .{ "css", .css },
    .{ "yaml", .yaml },             .{ "yml", .yaml },
    .{ "c", .c },                   .{ "cpp", .cpp },
    .{ "c++", .cpp },               .{ "cc", .cpp },
    .{ "cxx", .cpp },               .{ "hpp", .cpp },
    .{ "csharp", .csharp },         .{ "c#", .csharp },
    .{ "cs", .csharp },             .{ "java", .java },
    .{ "kotlin", .kotlin },         .{ "kt", .kotlin },
    .{ "kts", .kotlin },            .{ "swift", .swift },
    .{ "ruby", .ruby },             .{ "rb", .ruby },
    .{ "php", .php },               .{ "sql", .sql },
    .{ "lua", .lua },               .{ "dockerfile", .dockerfile },
    .{ "docker", .dockerfile },     .{ "nix", .nix },
    .{ "make", .make },             .{ "makefile", .make },
};

const alias_map = std.StaticStringMap(LanguageId).initComptime(alias_table);

/// Map a fence info string / alias / extension to a language. Only the first
/// whitespace-separated word counts, case-insensitively.
pub fn languageForAlias(alias: []const u8) ?LanguageId {
    var words = std.mem.tokenizeAny(u8, alias, " \t\n\r\x0c");
    const word = words.next() orelse return null;
    var buf: [16]u8 = undefined;
    if (word.len > buf.len) return null;
    return alias_map.get(std.ascii.lowerString(&buf, word));
}

/// Exact file names first (Dockerfile, Makefile, Cargo.toml, ...), then the
/// extension as an alias. Paths use `/` separators (Rust `Path` on Unix).
pub fn languageForPath(path: []const u8) ?LanguageId {
    const name = fileName(path) orelse return null;
    var buf: [32]u8 = undefined;
    if (name.len <= buf.len) {
        const lower = std.ascii.lowerString(&buf, name);
        const exact = std.StaticStringMap(LanguageId).initComptime(.{
            .{ "dockerfile", .dockerfile }, .{ "containerfile", .dockerfile },
            .{ "makefile", .make },         .{ "gnumakefile", .make },
            .{ "cargo.lock", .toml },       .{ "cargo.toml", .toml },
            .{ "pyproject.toml", .toml },
        });
        if (exact.get(lower)) |l| return l;
    }
    return languageForAlias(extension(name) orelse return null);
}

/// `Path::file_name`: the last normal component (trailing `/` and `.`
/// components ignored); null for `..` or an empty path.
fn fileName(path: []const u8) ?[]const u8 {
    var it = std.mem.splitBackwardsScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) {
            // `a/.` keeps `.` only as a leading component; trailing ones vanish.
            continue;
        }
        if (std.mem.eql(u8, comp, "..")) return null;
        return comp;
    }
    return null;
}

/// `Path::extension`: text after the last `.`, unless the name is `..` or the
/// only `.` is the leading one.
fn extension(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "..")) return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0) return null;
    return name[dot + 1 ..];
}

fn languageForShebang(line: []const u8) ?LanguageId {
    if (!std.mem.startsWith(u8, line, "#!")) return null;
    const rest = line[2..];
    if (containsIgnoreCase(rest, "python")) return .python;
    if (containsIgnoreCase(rest, "node")) return .javascript;
    if (containsIgnoreCase(rest, "ruby")) return .ruby;
    for ([_][]const u8{ "bash", "zsh", "/sh", " sh" }) |name| {
        if (containsIgnoreCase(rest, name)) return .bash;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

const testing = std.testing;

test "aliases keep language variants distinct" {
    const cases = [_]struct { []const u8, LanguageId }{
        .{ "js", .javascript }, .{ "jsx", .jsx },   .{ "ts", .typescript },
        .{ "tsx", .tsx },       .{ "RS", .rust },   .{ "shell", .bash },
    };
    for (cases) |case| try testing.expectEqual(@as(?LanguageId, case[1]), languageForAlias(case[0]));
    try testing.expectEqual(@as(?LanguageId, null), languageForAlias("unknown-lang"));
}

test "paths and exact names are table driven" {
    const cases = [_]struct { []const u8, LanguageId }{
        .{ "src/main.rs", .rust },   .{ "web/app.tsx", .tsx },     .{ "Cargo.toml", .toml },
        .{ "Dockerfile", .dockerfile }, .{ "GNUmakefile", .make }, .{ "config.jsonc", .jsonc },
    };
    for (cases) |case| try testing.expectEqual(@as(?LanguageId, case[1]), languageForPath(case[0]));
    try testing.expectEqual(@as(?LanguageId, null), languageForPath("README"));
    try testing.expectEqual(@as(?LanguageId, null), languageForPath("image.png"));
}

test "shebang is only used after explicit hints" {
    try testing.expectEqual(@as(?LanguageId, .python), detectLanguage(null, null, "#!/usr/bin/env python3"));
    try testing.expectEqual(@as(?LanguageId, null), detectLanguage(null, null, "let x = 1"));
}
