//! Composer completions: `/command` and `@mention` token detection (ports of
//! `slash_token` / `invocation_token` / `mention_token` in zeron
//! `crates/ui/src/composer.rs`) and the built-in Zeron workspace commands
//! (`WorkspaceCommand::catalog`). Provider slash commands, skills and file
//! search come from the engine and are wired by the composer when available.

const std = @import("std");

pub const Token = struct {
    start: usize,
    end: usize,
    /// The text after the trigger up to the caret.
    query: []const u8,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.' or c >= 0x80;
}

/// `invocation_token(text, cursor, prefix)`: a trigger at a token boundary
/// whose name so far is made of name characters.
pub fn invocationToken(text: []const u8, cursor: usize, prefix: u8) ?Token {
    if (cursor > text.len) return null;
    var start: usize = cursor;
    while (start > 0) {
        const c = text[start - 1];
        if (isSpace(c) or c == '(' or c == '[' or c == '{' or c == '>') break;
        start -= 1;
    }
    if (start >= cursor or text[start] != prefix) return null;
    const query = text[start + 1 .. cursor];
    for (query) |c| if (!isNameByte(c)) return null;
    if (prefix == '$' and query.len > 0 and std.ascii.isDigit(query[0])) return null;
    var end = start + 1;
    while (end < text.len and isNameByte(text[end])) end += 1;
    if (end < text.len and text[end] == '/') return null; // a path, not a command
    return .{ .start = start, .end = end, .query = query };
}

pub fn slashToken(text: []const u8, cursor: usize) ?Token {
    return invocationToken(text, cursor, '/');
}

/// `mention_token`: `@query` at a word boundary (also after `(`, `[`, `{`, `>`).
pub fn mentionToken(text: []const u8, cursor: usize) ?Token {
    if (cursor > text.len) return null;
    var token_start: usize = cursor;
    while (token_start > 0 and !isSpace(text[token_start - 1])) token_start -= 1;
    const rel = std.mem.lastIndexOfScalar(u8, text[token_start..cursor], '@') orelse return null;
    const at = token_start + rel;
    const valid = at == 0 or switch (text[at - 1]) {
        ' ', '\t', '\n', '\r', '(', '[', '{', '>' => true,
        else => false,
    };
    if (!valid) return null;
    var end = cursor;
    while (end < text.len and !isSpace(text[end])) end += 1;
    return .{ .start = at, .end = end, .query = text[at + 1 .. cursor] };
}

pub const WorkspaceCommand = enum { model, new, @"resume", settings, diff, files, terminal, rename, stop };

pub const CatalogEntry = struct {
    command: WorkspaceCommand,
    name: []const u8,
    description: []const u8,
    needs_chat: bool,
};

pub const catalog = [_]CatalogEntry{
    .{ .command = .model, .name = "model", .description = "Zeron: choose agent, model, and reasoning", .needs_chat = false },
    .{ .command = .new, .name = "new", .description = "Zeron: start a new conversation", .needs_chat = false },
    .{ .command = .@"resume", .name = "resume", .description = "Zeron: search and open conversations", .needs_chat = false },
    .{ .command = .settings, .name = "settings", .description = "Zeron: open settings", .needs_chat = false },
    .{ .command = .diff, .name = "diff", .description = "Zeron: open changes", .needs_chat = true },
    .{ .command = .files, .name = "files", .description = "Zeron: open project files", .needs_chat = true },
    .{ .command = .terminal, .name = "terminal", .description = "Zeron: open a terminal", .needs_chat = true },
    .{ .command = .rename, .name = "rename", .description = "Zeron: rename this conversation", .needs_chat = true },
    .{ .command = .stop, .name = "stop", .description = "Zeron: stop the active run", .needs_chat = true },
};

/// Catalog rows matching `query` (prefix matches first, then substring),
/// written into `out`.
pub fn filter(query: []const u8, in_chat: bool, out: []CatalogEntry) []CatalogEntry {
    var n: usize = 0;
    for ([_]bool{ true, false }) |prefix_pass| {
        for (catalog) |e| {
            if (e.needs_chat and !in_chat) continue;
            const is_prefix = std.ascii.startsWithIgnoreCase(e.name, query);
            const hit = if (prefix_pass) is_prefix else (!is_prefix and std.ascii.findIgnoreCase(e.name, query) != null);
            if (!hit or n == out.len) continue;
            out[n] = e;
            n += 1;
        }
    }
    return out[0..n];
}

/// The workspace command the whole draft names (`workspace_command_for_text`).
pub fn commandForText(text: []const u8, in_chat: bool) ?WorkspaceCommand {
    const trimmed_end = std.mem.trimEnd(u8, text, " \t\r\n").len;
    const t = slashToken(text, trimmed_end) orelse return null;
    if (std.mem.trim(u8, text[0..t.start], " \t\r\n").len != 0) return null;
    for (catalog) |e| {
        if (e.needs_chat and !in_chat) continue;
        if (std.mem.eql(u8, e.name, t.query)) return e.command;
    }
    return null;
}

const testing = std.testing;

test "slash tokens follow invocation_token boundaries" {
    const t = slashToken("/mo", 3).?;
    try testing.expectEqual(@as(usize, 0), t.start);
    try testing.expectEqualStrings("mo", t.query);
    try testing.expect(slashToken("a/b", 3) == null);
    try testing.expect(slashToken("see /usr/bin", 8) == null); // path
    const mid = slashToken("run (/new x", 8).?;
    try testing.expectEqual(@as(usize, 5), mid.start);
    try testing.expectEqual(@as(usize, 9), mid.end);
    try testing.expect(slashToken("/a b", 4) == null);
}

test "mention tokens" {
    const t = mentionToken("look at @src/ma", 15).?;
    try testing.expectEqualStrings("src/ma", t.query);
    try testing.expectEqual(@as(usize, 8), t.start);
    try testing.expect(mentionToken("mail@host", 9) == null);
    try testing.expect(mentionToken("plain", 5) == null);
}

test "workspace command catalog filter and exact match" {
    var buf: [16]CatalogEntry = undefined;
    const rows = filter("s", false, &buf);
    try testing.expectEqualStrings("settings", rows[0].name);
    try testing.expectEqual(@as(usize, 2), rows.len); // settings (prefix) + resume (substring)
    try testing.expectEqual(@as(usize, 9), filter("", true, &buf).len);
    try testing.expectEqual(@as(usize, 4), filter("", false, &buf).len);
    try testing.expectEqual(WorkspaceCommand.new, commandForText("/new ", false).?);
    try testing.expect(commandForText("hi /new", false) == null);
    try testing.expect(commandForText("/diff", false) == null);
}
