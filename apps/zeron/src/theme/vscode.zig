//! Offline VS Code theme normalization and conversion (port of zeron
//! `crates/theme/src/vscode.rs`). Deterministic and report-producing: a
//! JSONC theme file (with `include` chains, external token files, TextMate
//! `.tmTheme` plists and `semanticTokenColors`), or an extension package
//! (`package.json` → `contributes.themes`, each variant isolated), compiles
//! into Zeron `ThemeVariant`s cloned from Zeron Light/Dark, then hardened for
//! contrast. Every mapping, fallback, repair and validation finding lands in
//! an `ImportReport`.
//!
//! ```zig
//! var c = try vscode.compileSource(gpa, io, "/path/theme.json", .{ .family_id = "custom-x", .family_name = "x", ... });
//! defer c.deinit();
//! for (c.value.family.variants) |v| ...;          // compiled variants
//! c.value.reports.get(v.id)                        // per-variant report
//! ```
//!
//! Errors carry Rust's (anyhow outer-context) message in `Diagnostic`.

const std = @import("std");
const model = @import("model.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Color = model.Color;
const Appearance = model.Appearance;
const ThemeVariant = model.ThemeVariant;
const ThemeFamily = model.ThemeFamily;
const json = std.json;

pub const max_source_bytes: u64 = 4 * 1024 * 1024;
pub const max_include_depth: usize = 32;
pub const max_package_variants: usize = 128;

// ---- report types (serde-compatible field names) --------------------------------------

pub const ImportMapping = struct { zeronRole: []const u8, vscodeKey: []const u8, value: []const u8 };
pub const ImportAdjustment = struct { zeronRole: []const u8, original: []const u8, resolved: []const u8, reason: []const u8 };
pub const AccentCandidate = struct { vscodeKey: []const u8, value: []const u8 };

/// `zeron_theme::ValidationIssue` as serialized (snake_case `variant_id`).
pub const ReportIssue = struct {
    variant_id: []const u8,
    category: model.ValidationIssue.Category = .contrast,
    severity: model.ValidationIssue.Severity,
    message: []const u8,
};

pub const ImportReport = struct {
    sourceFiles: []const []const u8 = &.{},
    sourceHash: []const u8 = "",
    mappings: []const ImportMapping = &.{},
    fallbacks: []const []const u8 = &.{},
    dropped: []const []const u8 = &.{},
    warnings: []const []const u8 = &.{},
    adjustments: []const ImportAdjustment = &.{},
    accentCandidates: []const AccentCandidate = &.{},
    validation: []const ReportIssue = &.{},
};

pub const DetectedThemeSource = enum { file, package };

pub const VariantFailure = struct { id: []const u8, name: []const u8, path: []const u8, message: []const u8 };

pub const ReportEntry = struct { variant_id: []const u8, report: ImportReport };

pub const SourceCompilation = struct {
    path: []const u8,
    source_kind: DetectedThemeSource,
    family: ThemeFamily,
    /// Sorted by variant id (Rust `BTreeMap`).
    reports: []const ReportEntry,
    failures: []const VariantFailure,

    pub fn report(self: *const SourceCompilation, variant_id: []const u8) ?*const ImportReport {
        for (self.reports) |*r| if (std.mem.eql(u8, r.variant_id, variant_id)) return &r.report;
        return null;
    }
};

/// An arena-owned value.
pub fn Owned(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

pub const CompileOptions = struct {
    family_id: []const u8,
    family_name: []const u8,
    source_url: []const u8,
    revision: []const u8,
    license: []const u8,
};

pub const ImportOptions = struct {
    id: []const u8,
    family_id: []const u8,
    name: []const u8,
    appearance: Appearance,
    source_url: []const u8,
    revision: []const u8,
    license: []const u8,
};

/// The human-readable failure (Rust's anyhow outer context).
pub const Diagnostic = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            @memcpy(self.buf[self.buf.len - 3 ..], "...");
            break :blk self.buf[0..];
        };
        self.len = s.len;
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Error = error{ OutOfMemory, ImportFailed };

// ---- JSON5 / JSONC -----------------------------------------------------------------------

/// Normalize JSON5 (comments, trailing commas, single-quoted strings,
/// unquoted keys, `+`/hex numbers) into strict JSON.
pub fn json5ToJson(a: Allocator, src: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        // Comments.
        if (ch == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (ch == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i = @min(src.len, i + 2);
            continue;
        }
        // Strings.
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            try out.append(a, '"');
            i += 1;
            while (i < src.len and src[i] != quote) : (i += 1) {
                const c = src[i];
                if (c == '\\' and i + 1 < src.len) {
                    const n = src[i + 1];
                    i += 1;
                    switch (n) {
                        '\'' => try out.append(a, '\''),
                        '\n' => {}, // line continuation
                        '\r' => {
                            if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
                        },
                        else => try out.appendSlice(a, &.{ '\\', n }),
                    }
                    continue;
                }
                if (c == '"' and quote == '\'') {
                    try out.appendSlice(a, "\\\"");
                    continue;
                }
                if (c == '\n') {
                    try out.appendSlice(a, "\\n");
                    continue;
                }
                if (c == '\t') {
                    try out.appendSlice(a, "\\t");
                    continue;
                }
                try out.append(a, c);
            }
            try out.append(a, '"');
            i += 1;
            continue;
        }
        // Trailing commas: drop a comma followed (after blanks/comments) by } or ].
        if (ch == ',') {
            var j = i + 1;
            while (j < src.len) {
                if (std.ascii.isWhitespace(src[j])) {
                    j += 1;
                } else if (src[j] == '/' and j + 1 < src.len and src[j + 1] == '/') {
                    while (j < src.len and src[j] != '\n') j += 1;
                } else if (src[j] == '/' and j + 1 < src.len and src[j + 1] == '*') {
                    j += 2;
                    while (j + 1 < src.len and !(src[j] == '*' and src[j + 1] == '/')) j += 1;
                    j = @min(src.len, j + 2);
                } else break;
            }
            if (j < src.len and (src[j] == '}' or src[j] == ']')) {
                i += 1;
                continue;
            }
            try out.append(a, ',');
            i += 1;
            continue;
        }
        // Unquoted keys / identifiers (true/false/null/Infinity/NaN pass through).
        if (std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$') {
            var j = i;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_' or src[j] == '$')) j += 1;
            const word = src[i..j];
            var k = j;
            while (k < src.len and std.ascii.isWhitespace(src[k])) k += 1;
            const is_key = k < src.len and src[k] == ':';
            if (is_key) {
                try out.append(a, '"');
                try out.appendSlice(a, word);
                try out.append(a, '"');
            } else if (std.mem.eql(u8, word, "Infinity") or std.mem.eql(u8, word, "NaN")) {
                try out.appendSlice(a, "null");
            } else try out.appendSlice(a, word);
            i = j;
            continue;
        }
        // Numbers: leading '+', hex, bare decimal points.
        if (ch == '+' and i + 1 < src.len and (std.ascii.isDigit(src[i + 1]) or src[i + 1] == '.')) {
            i += 1;
            continue;
        }
        if (ch == '0' and i + 1 < src.len and (src[i + 1] == 'x' or src[i + 1] == 'X')) {
            var j = i + 2;
            while (j < src.len and std.ascii.isHex(src[j])) j += 1;
            const v = std.fmt.parseInt(u64, src[i + 2 .. j], 16) catch 0;
            try out.print(a, "{d}", .{v});
            i = j;
            continue;
        }
        if (ch == '.' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]) and (out.items.len == 0 or !std.ascii.isDigit(out.items[out.items.len - 1]))) {
            try out.appendSlice(a, "0.");
            i += 1;
            continue;
        }
        if (ch == '.' and (i + 1 >= src.len or !std.ascii.isDigit(src[i + 1])) and out.items.len > 0 and std.ascii.isDigit(out.items[out.items.len - 1])) {
            i += 1; // `1.` → `1`
            continue;
        }
        try out.append(a, ch);
        i += 1;
    }
    return out.items;
}

/// Parse JSON5 text into a `json.Value` (arena-owned; duplicate keys: last wins).
pub fn parseJson5(a: Allocator, src: []const u8) !json.Value {
    const strict = try json5ToJson(a, src);
    return json.parseFromSliceLeaky(json.Value, a, strict, .{ .duplicate_field_behavior = .use_last, .allocate = .alloc_always });
}

// ---- TextMate plist ------------------------------------------------------------------------

/// A minimal XML property-list reader (dict / array / string / integer /
/// real / true / false / data / date) into `json.Value`.
pub fn parsePlist(a: Allocator, src: []const u8) !json.Value {
    var p: PlistParser = .{ .a = a, .src = src };
    p.skipProlog();
    if (!p.startsWith("<plist")) return error.InvalidPlist;
    p.skipTag();
    p.skipWs();
    const v = try p.value();
    return v;
}

const PlistParser = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,

    fn startsWith(p: *PlistParser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.i..], s);
    }

    fn skipWs(p: *PlistParser) void {
        while (true) {
            while (p.i < p.src.len and std.ascii.isWhitespace(p.src[p.i])) p.i += 1;
            if (p.startsWith("<!--")) {
                const end = std.mem.indexOfPos(u8, p.src, p.i, "-->") orelse p.src.len;
                p.i = @min(p.src.len, end + 3);
                continue;
            }
            return;
        }
    }

    fn skipProlog(p: *PlistParser) void {
        while (true) {
            p.skipWs();
            if (p.startsWith("<?") or p.startsWith("<!DOCTYPE") or p.startsWith("<!doctype")) {
                p.skipTag();
                continue;
            }
            return;
        }
    }

    fn skipTag(p: *PlistParser) void {
        const end = std.mem.indexOfScalarPos(u8, p.src, p.i, '>') orelse p.src.len;
        p.i = @min(p.src.len, end + 1);
    }

    /// Reads `<name>` / `<name/>`; returns the name and whether it self-closed.
    fn openTag(p: *PlistParser) !struct { []const u8, bool } {
        p.skipWs();
        if (p.i >= p.src.len or p.src[p.i] != '<') return error.InvalidPlist;
        const end = std.mem.indexOfScalarPos(u8, p.src, p.i, '>') orelse return error.InvalidPlist;
        var inner = std.mem.trim(u8, p.src[p.i + 1 .. end], " \t\r\n");
        p.i = end + 1;
        const self_closing = inner.len > 0 and inner[inner.len - 1] == '/';
        if (self_closing) inner = std.mem.trim(u8, inner[0 .. inner.len - 1], " \t\r\n");
        const name_end = std.mem.indexOfAny(u8, inner, " \t\r\n") orelse inner.len;
        return .{ inner[0..name_end], self_closing };
    }

    fn text(p: *PlistParser, name: []const u8) ![]const u8 {
        var close_buf: [32]u8 = undefined;
        const close = try std.fmt.bufPrint(&close_buf, "</{s}>", .{name});
        const end = std.mem.indexOfPos(u8, p.src, p.i, close) orelse return error.InvalidPlist;
        const raw = p.src[p.i..end];
        p.i = end + close.len;
        return unescapeXml(p.a, raw);
    }

    fn value(p: *PlistParser) anyerror!json.Value {
        const name, const self_closing = try p.openTag();
        if (std.mem.eql(u8, name, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, name, "false")) return .{ .bool = false };
        if (std.mem.eql(u8, name, "dict")) {
            var map: json.ObjectMap = .empty;
            if (self_closing) return .{ .object = map };
            while (true) {
                p.skipWs();
                if (p.startsWith("</dict")) {
                    p.skipTag();
                    break;
                }
                const k, _ = try p.openTag();
                if (!std.mem.eql(u8, k, "key")) return error.InvalidPlist;
                const key = try p.text("key");
                const v = try p.value();
                try map.put(p.a, key, v);
            }
            return .{ .object = map };
        }
        if (std.mem.eql(u8, name, "array")) {
            var arr: json.Array = .init(p.a);
            if (self_closing) return .{ .array = arr };
            while (true) {
                p.skipWs();
                if (p.startsWith("</array")) {
                    p.skipTag();
                    break;
                }
                try arr.append(try p.value());
            }
            return .{ .array = arr };
        }
        if (self_closing) return .{ .string = "" };
        const t = try p.text(name);
        if (std.mem.eql(u8, name, "integer")) return .{ .integer = std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0 };
        if (std.mem.eql(u8, name, "real")) return .{ .float = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0 };
        return .{ .string = t };
    }
};

fn unescapeXml(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
                try out.append(a, raw[i]);
                i += 1;
                continue;
            };
            const ent = raw[i + 1 .. semi];
            if (std.mem.eql(u8, ent, "lt")) try out.append(a, '<') else if (std.mem.eql(u8, ent, "gt")) try out.append(a, '>') else if (std.mem.eql(u8, ent, "amp")) try out.append(a, '&') else if (std.mem.eql(u8, ent, "quot")) try out.append(a, '"') else if (std.mem.eql(u8, ent, "apos")) try out.append(a, '\'') else if (ent.len > 1 and ent[0] == '#') {
                const cp = if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) catch 0xfffd else std.fmt.parseInt(u21, ent[1..], 10) catch 0xfffd;
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &b) catch 0;
                try out.appendSlice(a, b[0..n]);
            } else try out.appendSlice(a, raw[i .. semi + 1]);
            i = semi + 1;
        } else {
            try out.append(a, raw[i]);
            i += 1;
        }
    }
    return out.items;
}

// ---- normalized source ---------------------------------------------------------------------

const TokenRule = struct { scopes: []const []const u8, foreground: ?[]const u8, font_style: ?[]const u8 };
const SemanticStyle = struct { foreground: ?[]const u8 = null, font_style: ?[]const u8 = null };

const Normalized = struct {
    /// key → value (last write wins, include parents first).
    colors: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    token_colors: std.ArrayList(TokenRule) = .empty,
    semantic: std.StringArrayHashMapUnmanaged(SemanticStyle) = .empty,
    files: std.ArrayList([]const u8) = .empty,

    fn color(self: *const Normalized, key: []const u8) ?[]const u8 {
        return self.colors.get(key);
    }
};

const Ctx = struct {
    a: Allocator,
    io: Io,
    diag: *Diagnostic,
};

fn fail(c: Ctx, comptime fmt: []const u8, args: anytype) Error {
    c.diag.set(fmt, args);
    return error.ImportFailed;
}

fn canonicalize(c: Ctx, path: []const u8) Error![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(c.io, path, c.a) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(c, "could not resolve {s}", .{path}),
    };
}

fn isDir(c: Ctx, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(c.io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn exists(c: Ctx, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(c.io, path, .{}) catch return false;
    return true;
}

fn readBounded(c: Ctx, path: []const u8, kind: []const u8) Error![]const u8 {
    const st = Io.Dir.cwd().statFile(c.io, path, .{}) catch return fail(c, "could not inspect {s} {s}", .{ kind, path });
    if (st.size > max_source_bytes) return fail(c, "{s} {s} is {d} bytes; the limit is {d}", .{ kind, path, st.size, max_source_bytes });
    return Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(max_source_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(c, "could not read {s} {s}", .{ kind, path }),
    };
}

fn parseJsonc(c: Ctx, src: []const u8, comptime what: []const u8, path: []const u8) Error!json.Value {
    return parseJson5(c.a, src) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(c, "could not parse " ++ what ++ " {s}", .{path}),
    };
}

fn resolveRelative(c: Ctx, owner: []const u8, relative: []const u8) Error![]const u8 {
    const dir = std.fs.path.dirname(owner) orelse ".";
    return std.fs.path.join(c.a, &.{ dir, relative });
}

fn startsWithPath(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/' or (root.len > 0 and root[root.len - 1] == '/');
}

fn ensureContained(c: Ctx, path: []const u8, root: []const u8, kind: []const u8) Error!void {
    if (!startsWithPath(path, root)) return fail(c, "{s} {s} resolves outside selected theme root {s}; symlinks are allowed only when their targets remain inside the root", .{ kind, path, root });
}

fn str(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn obj(v: ?json.Value) ?json.ObjectMap {
    const x = v orelse return null;
    return switch (x) {
        .object => |o| o,
        else => null,
    };
}

fn loadTheme(c: Ctx, path_in: []const u8, root: []const u8, stack: *std.ArrayList([]const u8)) Error!Normalized {
    const path = try canonicalize(c, path_in);
    try ensureContained(c, path, root, "theme source");
    for (stack.items) |p| if (std.mem.eql(u8, p, path)) return fail(c, "VS Code theme include cycle: {s}", .{path});
    if (stack.items.len >= max_include_depth) return fail(c, "VS Code theme include depth exceeds {d}", .{max_include_depth});
    try stack.append(c.a, path);
    const source = try readBounded(c, path, "theme source");
    const value = try parseJsonc(c, source, "JSONC theme", path);
    const object = obj(value) orelse return fail(c, "{s} is not a JSON object", .{path});

    var theme: Normalized = if (str(object.get("include"))) |include|
        try loadTheme(c, try resolveRelative(c, path, include), root, stack)
    else
        .{};
    try theme.files.append(c.a, path);

    if (obj(object.get("colors"))) |colors| {
        var it = colors.iterator();
        while (it.next()) |e| if (str(e.value_ptr.*)) |s| try theme.colors.put(c.a, e.key_ptr.*, s);
    }
    if (object.get("tokenColors")) |tc| switch (tc) {
        .array => |arr| try parseTokenRules(c.a, arr.items, &theme.token_colors),
        .string => |relative| {
            const token_path = try canonicalize(c, try resolveRelative(c, path, relative));
            try ensureContained(c, token_path, root, "external token file");
            try theme.files.append(c.a, token_path);
            try loadTokenFile(c, token_path, &theme.token_colors);
        },
        else => {},
    };
    if (obj(object.get("semanticTokenColors"))) |sem| {
        var it = sem.iterator();
        while (it.next()) |e| try theme.semantic.put(c.a, e.key_ptr.*, parseSemanticStyle(e.value_ptr.*));
    }
    _ = stack.pop();
    return theme;
}

fn splitScopes(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\r\n");
        if (t.len > 0) try out.append(a, t);
    }
    return out.items;
}

fn parseTokenRules(a: Allocator, values: []const json.Value, out: *std.ArrayList(TokenRule)) Allocator.Error!void {
    for (values) |v| {
        const o = obj(v) orelse continue;
        const scopes: []const []const u8 = if (o.get("scope")) |sc| switch (sc) {
            .string => |s| try splitScopes(a, s),
            .array => |arr| blk: {
                var list: std.ArrayList([]const u8) = .empty;
                for (arr.items) |x| if (str(x)) |s| try list.append(a, s);
                break :blk list.items;
            },
            else => &.{},
        } else &.{};
        const settings = obj(o.get("settings")) orelse continue;
        try out.append(a, .{ .scopes = scopes, .foreground = str(settings.get("foreground")), .font_style = str(settings.get("fontStyle")) });
    }
}

fn loadTokenFile(c: Ctx, path: []const u8, out: *std.ArrayList(TokenRule)) Error!void {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".tmTheme") or std.ascii.eqlIgnoreCase(ext, ".plist")) return loadTextmatePlist(c, path, out);
    const source = try readBounded(c, path, "token file");
    const value = try parseJsonc(c, source, "token file", path);
    const values: []const json.Value = switch (value) {
        .array => |arr| arr.items,
        .object => |o| if (o.get("tokenColors")) |tc| switch (tc) {
            .array => |arr| arr.items,
            else => return fail(c, "{s} does not contain token rules", .{path}),
        } else return fail(c, "{s} does not contain token rules", .{path}),
        else => return fail(c, "{s} does not contain token rules", .{path}),
    };
    try parseTokenRules(c.a, values, out);
}

fn loadTextmatePlist(c: Ctx, path: []const u8, out: *std.ArrayList(TokenRule)) Error!void {
    const st = Io.Dir.cwd().statFile(c.io, path, .{}) catch return fail(c, "could not inspect TextMate plist {s}", .{path});
    if (st.size > max_source_bytes) return fail(c, "TextMate plist {s} is {d} bytes; the limit is {d}", .{ path, st.size, max_source_bytes });
    const source = Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(max_source_bytes + 1)) catch return fail(c, "could not parse TextMate plist {s}", .{path});
    const value = parsePlist(c.a, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(c, "could not parse TextMate plist {s}", .{path}),
    };
    const dict = obj(value) orelse return fail(c, "{s} has no TextMate settings array", .{path});
    const settings: []const json.Value = if (dict.get("settings")) |s| switch (s) {
        .array => |arr| arr.items,
        else => return fail(c, "{s} has no TextMate settings array", .{path}),
    } else return fail(c, "{s} has no TextMate settings array", .{path});
    for (settings) |v| {
        const d = obj(v) orelse continue;
        const scopes: []const []const u8 = if (str(d.get("scope"))) |s| try splitScopes(c.a, s) else &.{};
        const style = obj(d.get("settings")) orelse continue;
        try out.append(c.a, .{ .scopes = scopes, .foreground = str(style.get("foreground")), .font_style = str(style.get("fontStyle")) });
    }
}

fn parseSemanticStyle(v: json.Value) SemanticStyle {
    return switch (v) {
        .string => |s| .{ .foreground = s },
        .object => |o| .{ .foreground = str(o.get("foreground")), .font_style = str(o.get("fontStyle")) },
        else => .{},
    };
}

// ---- compile -------------------------------------------------------------------------------

/// Detect and compile a single VS Code theme file or an extension package.
pub fn compileSource(gpa: Allocator, io: Io, path_in: []const u8, options_in: CompileOptions, diag: *Diagnostic) Error!Owned(SourceCompilation) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const c: Ctx = .{ .a = arena.allocator(), .io = io, .diag = diag };
    // The compilation owns everything it references (ids, names, provenance).
    const options: CompileOptions = .{
        .family_id = try c.a.dupe(u8, options_in.family_id),
        .family_name = try c.a.dupe(u8, options_in.family_name),
        .source_url = try c.a.dupe(u8, options_in.source_url),
        .revision = try c.a.dupe(u8, options_in.revision),
        .license = try c.a.dupe(u8, options_in.license),
    };
    const path = try canonicalize(c, path_in);
    const package_json: ?[]const u8 = if (isDir(c, path)) blk: {
        const candidate = try std.fs.path.join(c.a, &.{ path, "package.json" });
        break :blk if (exists(c, candidate)) candidate else null;
    } else if (std.mem.eql(u8, std.fs.path.basename(path), "package.json")) path else null;
    const value = if (package_json) |pj| try compilePackage(c, path, pj, options) else try compileSingleFile(c, path, options);
    return .{ .arena = arena, .value = value };
}

fn compileSingleFile(c: Ctx, path: []const u8, options: CompileOptions) Error!SourceCompilation {
    const parent = std.fs.path.dirname(path) orelse return fail(c, "{s} has no parent directory", .{path});
    const root = Io.Dir.cwd().realPathFileAlloc(c.io, parent, c.a) catch return fail(c, "could not resolve theme root for {s}", .{path});
    var stack: std.ArrayList([]const u8) = .empty;
    const normalized = try loadTheme(c, path, root, &stack);
    const appearance = detectAppearance(c, path, null, &normalized);
    const name = themeDeclaredName(c, path) orelse options.family_name;
    const imported = try convert(c, normalized, .{
        .id = options.family_id,
        .family_id = options.family_id,
        .name = name,
        .appearance = appearance,
        .source_url = options.source_url,
        .revision = options.revision,
        .license = options.license,
    });
    const variants = try c.a.alloc(ThemeVariant, 1);
    variants[0] = imported.theme;
    const reports = try c.a.alloc(ReportEntry, 1);
    reports[0] = .{ .variant_id = imported.theme.id, .report = imported.report };
    return .{
        .path = path,
        .source_kind = .file,
        .family = .{ .id = options.family_id, .name = options.family_name, .variants = variants },
        .reports = reports,
        .failures = &.{},
    };
}

fn compilePackage(c: Ctx, selected_path: []const u8, package_json: []const u8, options: CompileOptions) Error!SourceCompilation {
    const source = try readBounded(c, package_json, "package manifest");
    const manifest = parseJson5(c.a, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(c, "could not parse {s}", .{package_json}),
    };
    const m = obj(manifest) orelse return fail(c, "{s} does not declare contributes.themes", .{package_json});
    const contributes = obj(m.get("contributes"));
    const decls: []const json.Value = if (contributes) |ct| (if (ct.get("themes")) |t| switch (t) {
        .array => |arr| arr.items,
        else => null,
    } else null) orelse return fail(c, "{s} does not declare contributes.themes", .{package_json}) else return fail(c, "{s} does not declare contributes.themes", .{package_json});
    if (decls.len == 0) return fail(c, "{s} declares no theme variants", .{package_json});
    if (decls.len > max_package_variants) return fail(c, "{s} declares {d} theme variants; the limit is {d}", .{ package_json, decls.len, max_package_variants });
    const package_root_raw = std.fs.path.dirname(package_json) orelse return fail(c, "{s} has no parent directory", .{package_json});
    const package_root = Io.Dir.cwd().realPathFileAlloc(c.io, package_root_raw, c.a) catch return fail(c, "could not resolve package root {s}", .{package_root_raw});
    const family_name = blk: {
        const n = str(m.get("displayName")) orelse str(m.get("name"));
        if (n) |s| if (std.mem.trim(u8, s, " \t\r\n").len > 0) break :blk s;
        break :blk options.family_name;
    };
    var variants: std.ArrayList(ThemeVariant) = .empty;
    var reports: std.ArrayList(ReportEntry) = .empty;
    var failures: std.ArrayList(VariantFailure) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (decls, 0..) |decl, index| {
        const d = obj(decl);
        const label = blk: {
            if (d) |o| if (str(o.get("label"))) |l| if (std.mem.trim(u8, l, " \t\r\n").len > 0) break :blk l;
            break :blk try std.fmt.allocPrint(c.a, "Variant {d}", .{index + 1});
        };
        var id = try std.fmt.allocPrint(c.a, "{s}-{s}", .{ options.family_id, try slug(c.a, label) });
        if (used.contains(id)) {
            id = try std.fmt.allocPrint(c.a, "{s}-{d}", .{ id, index + 1 });
        }
        try used.put(c.a, id, {});
        const relative = if (d) |o| str(o.get("path")) else null;
        if (relative == null) {
            try failures.append(c.a, .{ .id = id, .name = label, .path = package_json, .message = "theme declaration has no path" });
            continue;
        }
        const theme_path = try std.fs.path.join(c.a, &.{ package_root, relative.? });
        var sub_diag: Diagnostic = .{};
        const sc: Ctx = .{ .a = c.a, .io = c.io, .diag = &sub_diag };
        const result = blk: {
            var stack: std.ArrayList([]const u8) = .empty;
            const normalized = loadTheme(sc, theme_path, package_root, &stack) catch |err| break :blk err;
            const appearance = detectAppearance(sc, theme_path, if (d) |o| str(o.get("uiTheme")) else null, &normalized);
            break :blk convert(sc, normalized, .{
                .id = id,
                .family_id = options.family_id,
                .name = label,
                .appearance = appearance,
                .source_url = options.source_url,
                .revision = options.revision,
                .license = options.license,
            });
        };
        if (result) |imported| {
            try reports.append(c.a, .{ .variant_id = imported.theme.id, .report = imported.report });
            try variants.append(c.a, imported.theme);
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try failures.append(c.a, .{ .id = id, .name = label, .path = theme_path, .message = try c.a.dupe(u8, sub_diag.message()) });
        }
    }
    if (variants.items.len == 0) {
        var details: std.ArrayList(u8) = .empty;
        for (failures.items, 0..) |f, i| {
            if (i > 0) try details.appendSlice(c.a, "; ");
            try details.print(c.a, "{s}: {s}", .{ f.name, f.message });
        }
        return fail(c, "no package variants compiled successfully: {s}", .{details.items});
    }
    std.mem.sort(ReportEntry, reports.items, {}, struct {
        fn lt(_: void, x: ReportEntry, y: ReportEntry) bool {
            return std.mem.lessThan(u8, x.variant_id, y.variant_id);
        }
    }.lt);
    return .{
        .path = selected_path,
        .source_kind = .package,
        .family = .{ .id = options.family_id, .name = family_name, .variants = variants.items },
        .reports = reports.items,
        .failures = failures.items,
    };
}

fn themeDeclaredName(c: Ctx, path: []const u8) ?[]const u8 {
    var d: Diagnostic = .{};
    const sc: Ctx = .{ .a = c.a, .io = c.io, .diag = &d };
    const source = readBounded(sc, path, "theme source") catch return null;
    const value = parseJson5(c.a, source) catch return null;
    const name = str((obj(value) orelse return null).get("name")) orelse return null;
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return null;
    return name;
}

fn explicitType(c: Ctx, path: []const u8) ?[]const u8 {
    const source = readBounded(c, path, "theme source") catch return null;
    const value = parseJson5(c.a, source) catch return null;
    return str((obj(value) orelse return null).get("type"));
}

fn detectAppearance(c: Ctx, path: []const u8, ui_theme: ?[]const u8, normalized: *const Normalized) Appearance {
    if (ui_theme) |u| {
        if (std.ascii.eqlIgnoreCase(u, "vs") or std.ascii.eqlIgnoreCase(u, "hc-light")) return .light;
        if (std.ascii.eqlIgnoreCase(u, "vs-dark") or std.ascii.eqlIgnoreCase(u, "hc-black")) return .dark;
    }
    var d: Diagnostic = .{};
    const sc: Ctx = .{ .a = c.a, .io = c.io, .diag = &d };
    if (explicitType(sc, path)) |kind| {
        if (std.ascii.eqlIgnoreCase(kind, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(kind, "dark")) return .dark;
    }
    if (normalized.color("editor.background")) |v| if (Color.parse(v)) |bg| {
        return if (Color.black.contrast(bg) > Color.white.contrast(bg)) .light else .dark;
    } else |_| {};
    return .dark;
}

/// `slug`: lowercase ASCII alphanumerics joined by single dashes ("theme" when empty).
pub fn slug(a: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var sep = false;
    var view = std.unicode.Utf8View.init(value) catch std.unicode.Utf8View.initUnchecked(value);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const lower: u21 = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
        if (lower < 128 and std.ascii.isAlphanumeric(@intCast(lower))) {
            if (sep and out.items.len > 0) try out.append(a, '-');
            sep = false;
            try out.append(a, @intCast(lower));
        } else sep = true;
    }
    if (out.items.len == 0) return "theme";
    return out.items;
}

// ---- convert -------------------------------------------------------------------------------

const Imported = struct { theme: ThemeVariant, report: ImportReport };

const Report = struct {
    a: Allocator,
    source_files: std.ArrayList([]const u8) = .empty,
    mappings: std.ArrayList(ImportMapping) = .empty,
    fallbacks: std.ArrayList([]const u8) = .empty,
    dropped: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
    adjustments: std.ArrayList(ImportAdjustment) = .empty,
    accent_candidates: std.ArrayList(AccentCandidate) = .empty,

    fn colorStr(self: *Report, col: Color) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.a, "{f}", .{col});
    }

    fn record(self: *Report, role: []const u8, original: Color, resolved: Color, reason: []const u8) Allocator.Error!void {
        if (original.eql(resolved)) return;
        try self.adjustments.append(self.a, .{ .zeronRole = role, .original = try self.colorStr(original), .resolved = try self.colorStr(resolved), .reason = reason });
    }
};

fn firstColor(r: *Report, theme: *const Normalized, keys: []const []const u8) Allocator.Error!?struct { []const u8, Color } {
    for (keys) |key| if (theme.color(key)) |value| {
        if (Color.parse(value)) |col| return .{ key, col } else |_| try r.warnings.append(r.a, try std.fmt.allocPrint(r.a, "ignored unsupported color {s}={s}", .{ key, value }));
    };
    return null;
}

fn apply(r: *Report, theme: *const Normalized, appearance: Appearance, role: []const u8, keys: []const []const u8, target: *Color) Allocator.Error!void {
    if (try firstColor(r, theme, keys)) |hit| {
        target.* = hit[1];
        try r.mappings.append(r.a, .{ .zeronRole = role, .vscodeKey = hit[0], .value = try r.colorStr(hit[1]) });
    } else {
        try r.fallbacks.append(r.a, try std.fmt.allocPrint(r.a, "{s} retained the Zeron {s} fallback", .{ role, if (appearance.isDark()) "dark" else "light" }));
    }
}

fn convert(c: Ctx, theme: Normalized, options: ImportOptions) Error!Imported {
    const a = c.a;
    const base_id = if (options.appearance.isDark()) "zeron-dark" else "zeron-light";
    var output = registry.builtin.variant(base_id).?.*;
    const fallback_background = output.colors.background;
    output.id = options.id;
    output.family_id = options.family_id;
    output.name = options.name;
    output.appearance = options.appearance;
    output.recommended_surface_treatment = .opaque_;

    var r: Report = .{ .a = a };
    for (theme.files.items) |p| try r.source_files.append(a, p);
    try r.fallbacks.append(a, "surface treatment inferred as opaque because VS Code palettes target solid workbench backgrounds; the user's Zeron surface preference can override it");
    const ap = options.appearance;
    const C = &output.colors;
    try apply(&r, &theme, ap, "background", &.{"editor.background"}, &C.background);
    try apply(&r, &theme, ap, "shell", &.{ "sideBar.background", "activityBar.background", "panel.background" }, &C.shell);
    try apply(&r, &theme, ap, "raised", &.{ "list.hoverBackground", "input.background" }, &C.raised);
    try apply(&r, &theme, ap, "card", &.{ "panel.background", "sideBar.background" }, &C.card);
    try apply(&r, &theme, ap, "dialog", &.{ "editorWidget.background", "quickInput.background" }, &C.dialog);
    try apply(&r, &theme, ap, "overlay", &.{ "dropdown.background", "menu.background", "editorWidget.background" }, &C.overlay);
    try apply(&r, &theme, ap, "hover", &.{ "list.hoverBackground", "toolbar.hoverBackground" }, &C.hover);
    try apply(&r, &theme, ap, "active", &.{ "list.activeSelectionBackground", "list.inactiveSelectionBackground" }, &C.active);
    try apply(&r, &theme, ap, "border", &.{ "panel.border", "widget.border", "contrastBorder" }, &C.border);
    try apply(&r, &theme, ap, "borderStrong", &.{ "focusBorder", "contrastActiveBorder" }, &C.border_strong);
    try apply(&r, &theme, ap, "text", &.{ "foreground", "editor.foreground" }, &C.text);
    try apply(&r, &theme, ap, "textMuted", &.{ "descriptionForeground", "tab.inactiveForeground" }, &C.text_muted);
    try apply(&r, &theme, ap, "textFaint", &.{ "disabledForeground", "input.placeholderForeground" }, &C.text_faint);
    try apply(&r, &theme, ap, "solid", &.{"button.background"}, &C.solid);
    try apply(&r, &theme, ap, "onSolid", &.{"button.foreground"}, &C.on_solid);
    try apply(&r, &theme, ap, "danger", &.{ "editorError.foreground", "errorForeground", "gitDecoration.deletedResourceForeground" }, &C.danger);
    try apply(&r, &theme, ap, "warning", &.{ "editorWarning.foreground", "gitDecoration.modifiedResourceForeground" }, &C.warning);
    try apply(&r, &theme, ap, "success", &.{ "gitDecoration.addedResourceForeground", "testing.iconPassed" }, &C.success);
    try apply(&r, &theme, ap, "input", &.{"input.background"}, &C.input);
    try apply(&r, &theme, ap, "cursor", &.{"editorCursor.foreground"}, &C.cursor);
    try apply(&r, &theme, ap, "diffAdd", &.{ "diffEditor.insertedTextBackground", "gitDecoration.addedResourceForeground" }, &C.diff_add);
    try apply(&r, &theme, ap, "diffDelete", &.{ "diffEditor.removedTextBackground", "gitDecoration.deletedResourceForeground" }, &C.diff_delete);
    try apply(&r, &theme, ap, "diffHunk", &.{ "diffEditor.diagonalFill", "editor.findMatchHighlightBackground" }, &C.diff_hunk);

    const accent_keys = [_][]const u8{ "focusBorder", "textLink.foreground", "button.background", "activityBarBadge.background", "progressBar.background", "editorCursor.foreground" };
    for (accent_keys) |key| if (theme.color(key)) |value| if (Color.parse(value)) |col| {
        try r.accent_candidates.append(a, .{ .vscodeKey = key, .value = try r.colorStr(col) });
    } else |_| {};
    if (r.accent_candidates.items.len > 0) {
        const cand = r.accent_candidates.items[0];
        const primary = Color.parse(cand.value) catch unreachable;
        output.accent = model.AccentRoles.derive(primary, ap, output.colors.background);
        try r.mappings.append(a, .{ .zeronRole = "accent.*", .vscodeKey = cand.vscodeKey, .value = cand.value });
    } else {
        try r.fallbacks.append(a, "accent.* retained the Zeron fallback; curate a native accent");
    }

    try apply(&r, &theme, ap, "terminal.background", &.{"terminal.background"}, &output.terminal.background);
    try apply(&r, &theme, ap, "terminal.foreground", &.{"terminal.foreground"}, &output.terminal.foreground);
    try apply(&r, &theme, ap, "terminal.selection", &.{"terminal.selectionBackground"}, &output.terminal.selection);
    const ansi_keys = [_][]const u8{
        "terminal.ansiBlack",       "terminal.ansiRed",        "terminal.ansiGreen",        "terminal.ansiYellow",
        "terminal.ansiBlue",        "terminal.ansiMagenta",    "terminal.ansiCyan",         "terminal.ansiWhite",
        "terminal.ansiBrightBlack", "terminal.ansiBrightRed",  "terminal.ansiBrightGreen",  "terminal.ansiBrightYellow",
        "terminal.ansiBrightBlue",  "terminal.ansiBrightMagenta", "terminal.ansiBrightCyan", "terminal.ansiBrightWhite",
    };
    for (ansi_keys, 0..) |key, i| {
        try apply(&r, &theme, ap, try std.fmt.allocPrint(a, "terminal.ansi[{d}]", .{i}), &.{key}, &output.terminal.ansi[i]);
    }

    try mapSyntax(&theme, &output, &r);
    try hardenVariant(&theme, &output, fallback_background, &r);

    // Source hash: every contributing file, in load order.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (theme.files.items) |p| hasher.update(try readBounded(c, p, "theme source while hashing"));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const source_hash = try std.fmt.allocPrint(a, "sha256:{s}", .{&hex});

    output.source = .{ .format = "vscode", .url = options.source_url, .revision = options.revision, .license = options.license, .asset_hash = "" };
    const asset = output.computeAssetHash();
    output.source.asset_hash = try a.dupe(u8, &asset);

    // Validation of the resolved palette.
    const fam = [_]ThemeFamily{.{ .id = output.family_id, .name = output.name, .variants = &.{output} }};
    const reg: model.Registry = .{ .families = &fam };
    var issues = try reg.validate(a);
    var validation = try a.alloc(ReportIssue, issues.items.len);
    for (issues.items, 0..) |iss, i| validation[i] = .{ .variant_id = iss.variant_id, .category = iss.category, .severity = iss.severity, .message = iss.message };
    issues.deinit(a);

    return .{ .theme = output, .report = .{
        .sourceFiles = r.source_files.items,
        .sourceHash = source_hash,
        .mappings = r.mappings.items,
        .fallbacks = r.fallbacks.items,
        .dropped = r.dropped.items,
        .warnings = r.warnings.items,
        .adjustments = r.adjustments.items,
        .accentCandidates = r.accent_candidates.items,
        .validation = validation,
    } };
}

fn minimumContrast(col: Color, backgrounds: []const Color) f32 {
    var m: f32 = std.math.inf(f32);
    for (backgrounds) |b| m = @min(m, col.contrast(b));
    return m;
}

fn ensureContrastAcross(col: Color, backgrounds: []const Color, minimum: f32, preferred: ?Color) Color {
    if (minimumContrast(col, backgrounds) >= minimum) return col;
    var targets: [3]Color = undefined;
    var n: usize = 0;
    if (preferred) |p| {
        targets[n] = p;
        n += 1;
    }
    targets[n] = Color.black;
    targets[n + 1] = Color.white;
    n += 2;
    var best = col;
    var best_contrast = minimumContrast(col, backgrounds);
    for (targets[0..n]) |target| {
        var step: u32 = 1;
        while (step <= 100) : (step += 1) {
            const candidate = col.mix(target, @as(f32, @floatFromInt(step)) / 100.0);
            const contrast = minimumContrast(candidate, backgrounds);
            if (contrast > best_contrast) {
                best = candidate;
                best_contrast = contrast;
            }
            if (contrast >= minimum) return candidate;
        }
    }
    return best;
}

fn flattenFoundation(r: *Report, role: []const u8, col: Color, background: Color) Allocator.Error!Color {
    if (col.a == 255) return col;
    const resolved = col.blendOver(background);
    try r.record(role, col, resolved, "flattened a translucent foundational surface against the theme background");
    return resolved;
}

fn hardenForeground(
    source: *const Normalized,
    r: *Report,
    role: []const u8,
    current: Color,
    candidate_keys: []const []const u8,
    backgrounds: []const Color,
    minimum: f32,
    preferred: ?Color,
) Allocator.Error!Color {
    const current_contrast = minimumContrast(current, backgrounds);
    if (current_contrast >= minimum) return current;
    for (candidate_keys) |key| {
        const value = source.color(key) orelse continue;
        const candidate = Color.parse(value) catch continue;
        if (minimumContrast(candidate, backgrounds) >= minimum) {
            try r.record(role, current, candidate, try std.fmt.allocPrint(r.a, "used {s} because the mapped color reached only {d:.2}:1", .{ key, current_contrast }));
            for (r.mappings.items) |*m| if (std.mem.eql(u8, m.zeronRole, role)) {
                m.vscodeKey = key;
                m.value = try r.colorStr(candidate);
                break;
            };
            return candidate;
        }
    }
    const resolved = ensureContrastAcross(current, backgrounds, minimum, preferred);
    try r.record(role, current, resolved, try std.fmt.allocPrint(r.a, "preserved the source hue while raising worst-case contrast from {d:.2}:1 to {d:.2}:1", .{ current_contrast, minimumContrast(resolved, backgrounds) }));
    return resolved;
}

fn hardenVariant(source: *const Normalized, output: *ThemeVariant, fallback_background: Color, r: *Report) Allocator.Error!void {
    const C = &output.colors;
    C.background = try flattenFoundation(r, "background", C.background, fallback_background);
    const background = C.background;
    C.shell = try flattenFoundation(r, "shell", C.shell, background);
    C.raised = try flattenFoundation(r, "raised", C.raised, background);
    C.card = try flattenFoundation(r, "card", C.card, background);
    C.dialog = try flattenFoundation(r, "dialog", C.dialog, background);
    C.overlay = try flattenFoundation(r, "overlay", C.overlay, background);
    C.input = try flattenFoundation(r, "input", C.input, background);
    C.solid = try flattenFoundation(r, "solid", C.solid, background);
    output.terminal.background = try flattenFoundation(r, "terminal.background", output.terminal.background, background);

    const text_bgs = [_]Color{ background, C.shell, C.raised, C.card, C.dialog, C.overlay, C.input };
    C.text = try hardenForeground(source, r, "text", C.text, &.{ "foreground", "sideBar.foreground", "editorWidget.foreground", "quickInput.foreground", "input.foreground", "menu.foreground", "editor.foreground" }, &text_bgs, 4.5, null);
    C.text_muted = try hardenForeground(source, r, "textMuted", C.text_muted, &.{ "descriptionForeground", "tab.inactiveForeground", "sideBarSectionHeader.foreground" }, &text_bgs, 4.5, C.text);
    C.text_faint = try hardenForeground(source, r, "textFaint", C.text_faint, &.{ "disabledForeground", "input.placeholderForeground", "descriptionForeground", "foreground" }, &text_bgs, 3.0, C.text_muted);
    C.on_solid = try hardenForeground(source, r, "onSolid", C.on_solid, &.{ "button.foreground", "foreground", "editor.foreground" }, &.{C.solid}, 4.5, C.text);
    output.terminal.foreground = try hardenForeground(source, r, "terminal.foreground", output.terminal.foreground, &.{ "terminal.foreground", "editor.foreground", "foreground" }, &.{output.terminal.background}, 4.5, C.text);

    const roles = [_]struct { []const u8, *Color }{
        .{ "danger", &C.danger },
        .{ "warning", &C.warning },
        .{ "success", &C.success },
        .{ "cursor", &C.cursor },
        .{ "borderStrong", &C.border_strong },
    };
    for (roles) |role| {
        const original = role[1].*;
        role[1].* = ensureContrastAcross(original, text_bgs[0..2], 3.0, null);
        try r.record(role[0], original, role[1].*, "raised to 3:1 across the main and shell surfaces");
    }
    try hardenAccent(output, r, text_bgs[0..4]);
}

fn hardenAccent(output: *ThemeVariant, r: *Report, backgrounds: []const Color) Allocator.Error!void {
    const current = output.accent.primary;
    if (minimumContrast(current, backgrounds) >= 3.0) return;
    for (r.accent_candidates.items) |cand| {
        const primary = Color.parse(cand.value) catch continue;
        if (minimumContrast(primary, backgrounds) >= 3.0) {
            output.accent = model.AccentRoles.derive(primary, output.appearance, output.colors.background);
            try r.record("accent.*", current, output.accent.primary, try std.fmt.allocPrint(r.a, "used {s} to keep interactions at 3:1", .{cand.vscodeKey}));
            return;
        }
    }
    const primary = ensureContrastAcross(current, backgrounds, 3.0, null);
    output.accent = model.AccentRoles.derive(primary, output.appearance, output.colors.background);
    try r.record("accent.*", current, output.accent.primary, "preserved the source hue while raising interaction contrast to 3:1");
}

fn mapSyntax(theme: *const Normalized, output: *ThemeVariant, r: *Report) Allocator.Error!void {
    for (theme.token_colors.items) |rule| {
        const fg = rule.foreground orelse continue;
        const col = Color.parse(fg) catch {
            try r.warnings.append(r.a, try std.fmt.allocPrint(r.a, "ignored TextMate color {s}", .{fg}));
            continue;
        };
        if (rule.font_style) |style| if (style.len > 0) {
            try r.dropped.append(r.a, try std.fmt.allocPrint(r.a, "TextMate fontStyle `{s}` for {s}", .{ style, try std.mem.join(r.a, ", ", rule.scopes) }));
        };
        for (rule.scopes) |scope| if (syntaxRoleForScope(scope)) |role| {
            output.syntax.set(model.SyntaxKey.fromWireName(role).?, col);
            try r.mappings.append(r.a, .{ .zeronRole = try std.fmt.allocPrint(r.a, "syntax.{s}", .{role}), .vscodeKey = scope, .value = try r.colorStr(col) });
        };
    }
    // BTreeMap order: selectors sorted.
    const keys = try r.a.dupe([]const u8, theme.semantic.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (keys) |selector| {
        const style = theme.semantic.get(selector).?;
        if (style.font_style) |fs| if (fs.len > 0) {
            try r.dropped.append(r.a, try std.fmt.allocPrint(r.a, "semantic fontStyle `{s}` for {s}", .{ fs, selector }));
        };
        const fg = style.foreground orelse continue;
        const col = Color.parse(fg) catch continue;
        if (syntaxRoleForSemantic(selector)) |role| {
            output.syntax.set(model.SyntaxKey.fromWireName(role).?, col);
            try r.mappings.append(r.a, .{ .zeronRole = try std.fmt.allocPrint(r.a, "syntax.{s}", .{role}), .vscodeKey = try std.fmt.allocPrint(r.a, "semantic:{s}", .{selector}), .value = try r.colorStr(col) });
        }
    }
}

pub fn syntaxRoleForScope(scope: []const u8) ?[]const u8 {
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "comment", "comment" },                     .{ "invalid", "invalid" },
        .{ "keyword", "keyword" },                     .{ "storage", "keyword" },
        .{ "string", "string" },                       .{ "constant.numeric", "number" },
        .{ "constant.language", "boolean" },           .{ "entity.name.type", "type" },
        .{ "support.type", "typeBuiltin" },            .{ "entity.name.function", "function" },
        .{ "support.function", "functionBuiltin" },    .{ "entity.other.attribute", "attribute" },
        .{ "entity.name.tag", "tag" },                 .{ "variable.parameter", "parameter" },
        .{ "variable.other.property", "property" },    .{ "variable", "variable" },
        .{ "constant", "constant" },                   .{ "keyword.operator", "operator" },
        .{ "punctuation", "punctuation" },
    };
    for (pairs) |p| if (std.ascii.findIgnoreCase(scope, p[0]) != null) return p[1];
    return null;
}

pub fn syntaxRoleForSemantic(selector: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, selector, ".:") orelse selector.len;
    const token = selector[0..end];
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(token, "comment")) return "comment";
    if (eq(token, "keyword") or eq(token, "modifier")) return "keyword";
    if (eq(token, "string") or eq(token, "regexp")) return "string";
    if (eq(token, "number")) return "number";
    if (eq(token, "type") or eq(token, "class") or eq(token, "interface") or eq(token, "enum") or eq(token, "struct")) return "type";
    if (eq(token, "function") or eq(token, "method")) return "function";
    if (eq(token, "property") or eq(token, "enummember")) return "property";
    if (eq(token, "parameter")) return "parameter";
    if (eq(token, "variable")) return "variable";
    if (eq(token, "macro")) return "macro";
    if (eq(token, "decorator")) return "attribute";
    return null;
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "JSON5 normalization: comments, trailing commas, quotes, bare keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseJson5(a,
        \\{
        \\  // line comment
        \\  name: 'It\'s "mine"', /* block */
        \\  "colors": { "editor.background": "#1e1e1e", },
        \\  list: [1, +2, 0x10, .5, 3.,],
        \\  "url": "http://x//y",
        \\}
    );
    const o = v.object;
    try testing.expectEqualStrings("It's \"mine\"", o.get("name").?.string);
    try testing.expectEqualStrings("#1e1e1e", o.get("colors").?.object.get("editor.background").?.string);
    try testing.expectEqual(@as(usize, 5), o.get("list").?.array.items.len);
    try testing.expectEqualStrings("http://x//y", o.get("url").?.string);
}

test "TextMate plist reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parsePlist(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\  <key>name</key><string>Mono &amp; Co</string>
        \\  <key>settings</key><array>
        \\    <dict><key>settings</key><dict><key>foreground</key><string>#ffffff</string></dict></dict>
        \\    <dict><key>scope</key><string>comment, string</string><key>settings</key><dict><key>foreground</key><string>#888888</string><key>fontStyle</key><string>italic</string></dict></dict>
        \\  </array>
        \\  <key>flag</key><true/>
        \\</dict></plist>
    );
    try testing.expectEqualStrings("Mono & Co", v.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), v.object.get("settings").?.array.items.len);
    try testing.expect(v.object.get("flag").?.bool);
}

test "scope and semantic roles" {
    try testing.expectEqualStrings("comment", syntaxRoleForScope("comment.line.double-slash").?);
    try testing.expectEqualStrings("keyword", syntaxRoleForScope("keyword.operator.new").?);
    try testing.expectEqualStrings("typeBuiltin", syntaxRoleForScope("support.type.primitive").?);
    try testing.expect(syntaxRoleForScope("meta.block") == null);
    try testing.expectEqualStrings("type", syntaxRoleForSemantic("class.declaration:rust").?);
    try testing.expectEqualStrings("attribute", syntaxRoleForSemantic("decorator").?);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("my-cool-theme", try slug(arena.allocator(), "My Cool Theme!"));
    try testing.expectEqualStrings("theme", try slug(arena.allocator(), "!!"));
}

test "compile a single JSONC theme: mapping, hardening, report, include + token file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "base.json", .data =
        \\{ "colors": { "editor.background": "#ffffff", "focusBorder": "#0066cc" } }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tokens.json", .data =
        \\[ { "scope": "comment", "settings": { "foreground": "#6a9955", "fontStyle": "italic" } } ]
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "night.json", .data =
        \\{
        \\  // A dark theme on top of a light base
        \\  "name": "Night Owl",
        \\  "type": "dark",
        \\  "include": "./base.json",
        \\  "colors": { "editor.background": "#011627", "foreground": "#2b3a4a", "button.background": "#7e57c2", },
        \\  "tokenColors": "./tokens.json",
        \\  "semanticTokenColors": { "function": "#82aaff", "variable.readonly": { "foreground": "#addb67", "fontStyle": "bold" } },
        \\}
    });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "night.json" });
    defer testing.allocator.free(path);
    var diag: Diagnostic = .{};
    var c = try compileSource(testing.allocator, testing.io, path, .{ .family_id = "custom-night", .family_name = "night", .source_url = path, .revision = "local", .license = "User supplied" }, &diag);
    defer c.deinit();
    const comp = c.value;
    try testing.expectEqual(DetectedThemeSource.file, comp.source_kind);
    try testing.expectEqual(@as(usize, 1), comp.family.variants.len);
    const v = comp.family.variants[0];
    try testing.expectEqualStrings("Night Owl", v.name);
    try testing.expectEqualStrings("custom-night", v.id);
    try testing.expectEqual(Appearance.dark, v.appearance);
    try testing.expect(v.colors.background.eql(Color.hex("#011627")));
    // The too-dark foreground was hardened to ≥ 4.5:1.
    try testing.expect(v.colors.text.contrast(v.colors.background) >= 4.5);
    try testing.expect(v.syntax.get(.comment).?.eql(Color.hex("#6a9955")));
    try testing.expect(v.syntax.get(.function).?.eql(Color.hex("#82aaff")));
    try testing.expect(v.syntax.get(.variable).?.eql(Color.hex("#addb67")));
    try testing.expectEqual(model.SurfaceTreatment.opaque_, v.recommended_surface_treatment);
    const rep = comp.report("custom-night").?;
    try testing.expectEqual(@as(usize, 3), rep.sourceFiles.len); // base, night, tokens
    try testing.expect(std.mem.startsWith(u8, rep.sourceHash, "sha256:"));
    try testing.expect(rep.adjustments.len > 0);
    try testing.expectEqualStrings("focusBorder", rep.accentCandidates[0].vscodeKey);
    try testing.expectEqual(@as(usize, 2), rep.dropped.len);
    try testing.expect(std.mem.startsWith(u8, v.source.asset_hash, "sha256:"));
}

test "packages isolate failing variants; missing files and cycles fail clearly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "pkg/themes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/package.json", .data =
        \\{ "displayName": "Pack", "contributes": { "themes": [
        \\  { "label": "Day", "uiTheme": "vs", "path": "./themes/day.json" },
        \\  { "label": "Broken", "uiTheme": "vs-dark", "path": "./themes/missing.json" },
        \\] } }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/themes/day.json", .data =
        \\{ "colors": { "editor.background": "#fafafa", "foreground": "#333333" } }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "loop.json", .data =
        \\{ "include": "./loop.json" }
    });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const pkg = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "pkg" });
    defer testing.allocator.free(pkg);
    var diag: Diagnostic = .{};
    var c = try compileSource(testing.allocator, testing.io, pkg, .{ .family_id = "custom-pkg", .family_name = "pkg", .source_url = pkg, .revision = "local", .license = "User supplied" }, &diag);
    defer c.deinit();
    try testing.expectEqual(DetectedThemeSource.package, c.value.source_kind);
    try testing.expectEqualStrings("Pack", c.value.family.name);
    try testing.expectEqual(@as(usize, 1), c.value.family.variants.len);
    try testing.expectEqualStrings("custom-pkg-day", c.value.family.variants[0].id);
    try testing.expectEqual(Appearance.light, c.value.family.variants[0].appearance);
    try testing.expectEqual(@as(usize, 1), c.value.failures.len);
    try testing.expectEqualStrings("Broken", c.value.failures[0].name);

    const loop = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "loop.json" });
    defer testing.allocator.free(loop);
    try testing.expectError(error.ImportFailed, compileSource(testing.allocator, testing.io, loop, .{ .family_id = "x", .family_name = "x", .source_url = "", .revision = "", .license = "" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "include cycle") != null);
    try testing.expectError(error.ImportFailed, compileSource(testing.allocator, testing.io, "/nonexistent/theme.json", .{ .family_id = "x", .family_name = "x", .source_url = "", .revision = "", .license = "" }, &diag));
    try testing.expectEqualStrings("could not resolve /nonexistent/theme.json", diag.message());
}
