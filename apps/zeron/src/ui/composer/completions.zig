//! Provider completions for the composer — pure ports of zeron
//! `composer.rs` (`InvocationCandidate`, `invocation_candidates`,
//! `with_workspace_commands`, `completion_trigger`, `invocation_insertion`)
//! and `crates/proto/src/invocation.rs` (`Invocation::link`,
//! `prompt_text`, the name/path validators).
//!
//! A `/` token lists the agent's slash commands (`ListCommands`) and, unless
//! the per-agent preference separates them, its skills (`ListSkills`), plus
//! Zeron's own workspace commands; `$` lists skills only (when enabled).
//! Accepting a provider row inserts the canonical reference link
//! `[/name](zeron-invoke:<hex json>)` (or plain `/name ` for hosts without
//! `composer-references-v1`).

const std = @import("std");
const engine = @import("zeron_engine");
const slash = @import("slash.zig");

const protocol = engine.protocol;
const Allocator = std.mem.Allocator;

pub const invocation_scheme = "zeron-invoke:";

/// `SlashCommand` (agent.rs).
pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8 = "",
    inputHint: ?[]const u8 = null,
};

pub const SkillCommand = struct { name: []const u8, harness: []const u8 };

/// `invocation::Skill`.
pub const Skill = struct {
    name: []const u8,
    path: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    command: ?SkillCommand = null,
};

pub const Invocation = union(enum) {
    command: struct { name: []const u8 },
    skill: struct { name: []const u8, path: []const u8, command: ?SkillCommand = null },

    pub fn name(self: Invocation) []const u8 {
        return switch (self) {
            inline else => |v| v.name,
        };
    }

    pub fn prefix(self: Invocation) u8 {
        return switch (self) {
            .command => '/',
            .skill => '$',
        };
    }

    /// serde's `{"kind":…,…}` with `skip_serializing_if = None`.
    fn writeJson(self: Invocation, w: *std.Io.Writer) !void {
        var s: std.json.Stringify = .{ .writer = w };
        switch (self) {
            .command => |c| {
                try s.beginObject();
                try s.objectField("kind");
                try s.write("command");
                try s.objectField("name");
                try s.write(c.name);
                try s.endObject();
            },
            .skill => |k| {
                try s.beginObject();
                try s.objectField("kind");
                try s.write("skill");
                try s.objectField("name");
                try s.write(k.name);
                try s.objectField("path");
                try s.write(k.path);
                if (k.command) |c| {
                    try s.objectField("command");
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(c.name);
                    try s.objectField("harness");
                    try s.write(c.harness);
                    try s.endObject();
                }
                try s.endObject();
            },
        }
    }

    /// `Invocation::link`: `[{prefix}{label}](zeron-invoke:{hex json})`.
    pub fn link(self: Invocation, gpa: Allocator) ![]u8 {
        var json: std.Io.Writer.Allocating = .init(gpa);
        defer json.deinit();
        try self.writeJson(&json.writer);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeByte('[');
        try aw.writer.writeByte(self.prefix());
        try writeLabel(&aw.writer, self.name());
        try aw.writer.writeAll("](" ++ invocation_scheme);
        for (json.written()) |b| try aw.writer.print("{x:0>2}", .{b});
        try aw.writer.writeByte(')');
        return aw.toOwnedSlice();
    }

    /// `Invocation::prompt_text` (hosts without reference delivery).
    pub fn promptText(self: Invocation, gpa: Allocator) ![]u8 {
        switch (self) {
            .command => |c| return std.fmt.allocPrint(gpa, "/{s}", .{c.name}),
            .skill => |k| {
                if (nativeSkillIdentity(k.path)) return gpa.dupe(u8, k.name);
                var aw: std.Io.Writer.Allocating = .init(gpa);
                errdefer aw.deinit();
                try aw.writer.writeAll("[$");
                try writeLabel(&aw.writer, k.name);
                try aw.writer.writeAll("](");
                for (k.path) |b| {
                    if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "/-._~:", b) != null) {
                        try aw.writer.writeByte(b);
                    } else try aw.writer.print("%{X:0>2}", .{b});
                }
                try aw.writer.writeByte(')');
                return aw.toOwnedSlice();
            },
        }
    }
};

fn writeLabel(w: *std.Io.Writer, label: []const u8) !void {
    for (label) |c| switch (c) {
        '\\', '[', ']', '`' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
}

pub fn nativeSkillIdentity(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "opencode-skill:") or std.mem.startsWith(u8, path, "harness-skill:");
}

pub fn validInvocationName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |c| if (c < 0x20 or c == 0x7f or std.ascii.isWhitespace(c)) return false;
    return true;
}

pub fn validSkillPath(p: []const u8) bool {
    if (p.len == 0) return false;
    for (p) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn validSkillCommandName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '-' or c == '_' or c == ':' or c == '.')) return false;
    return true;
}

/// One completion row (`InvocationCandidate`).
pub const Candidate = struct {
    name: []const u8,
    description: []const u8,
    input_hint: ?[]const u8 = null,
    invocation: Invocation,
    /// Zeron's own command (executes instead of inserting).
    workspace: ?slash.WorkspaceCommand = null,
};

/// `invocation_candidates`: valid commands (minus skill aliases), then the
/// enabled skills; everything allocated in `arena`.
pub fn invocationCandidates(arena: Allocator, commands: []const SlashCommand, skills: []const Skill) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    var valid_skills: std.ArrayList(Skill) = .empty;
    for (skills) |s| {
        if (!validInvocationName(s.name) or !validSkillPath(s.path)) continue;
        if (s.command) |c| if (!validSkillCommandName(c.name)) continue;
        try valid_skills.append(arena, s);
    }
    for (commands) |c| {
        if (!validInvocationName(c.name)) continue;
        var alias = false;
        for (valid_skills.items) |s| if (s.command) |sc| if (std.mem.eql(u8, sc.name, c.name)) {
            alias = true;
        };
        if (alias) continue;
        try out.append(arena, .{ .name = c.name, .description = c.description, .input_hint = c.inputHint, .invocation = .{ .command = .{ .name = c.name } } });
    }
    for (valid_skills.items) |s| {
        if (!s.enabled) continue;
        const desc = if (nativeSkillIdentity(s.path)) s.description else try std.fmt.allocPrint(arena, "{s} \u{2014} {s}", .{ s.description, s.path });
        try out.append(arena, .{ .name = s.name, .description = desc, .invocation = .{ .skill = .{ .name = s.name, .path = s.path, .command = s.command } } });
    }
    return out.items;
}

/// `with_workspace_commands`: provider rows keep their names; Zeron's
/// commands follow (renamed `zeron:name` when a provider owns the name).
pub fn withWorkspaceCommands(arena: Allocator, rows: []const Candidate, in_chat: bool) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (rows) |r| if (r.workspace == null) try out.append(arena, r);
    for (slash.catalog) |e| {
        if (e.needs_chat and !in_chat) continue;
        var n: []const u8 = e.name;
        while (true) {
            var clash = false;
            for (out.items) |r| if (std.mem.eql(u8, r.name, n)) {
                clash = true;
            };
            if (!clash) break;
            n = try std.fmt.allocPrint(arena, "zeron:{s}", .{n});
        }
        try out.append(arena, .{ .name = n, .description = e.description, .invocation = .{ .command = .{ .name = n } }, .workspace = e.command });
    }
    return out.items;
}

/// Prefix matches first, then substring (case-insensitive, stable).
pub fn filter(query: []const u8, rows: []const Candidate, out: []usize) []usize {
    var n: usize = 0;
    for ([_]bool{ true, false }) |prefix_pass| {
        for (rows, 0..) |r, ix| {
            if (n == out.len) break;
            const is_prefix = std.ascii.startsWithIgnoreCase(r.name, query);
            const hit = if (prefix_pass) is_prefix else (!is_prefix and std.ascii.findIgnoreCase(r.name, query) != null);
            if (!hit) continue;
            out[n] = ix;
            n += 1;
        }
    }
    return out[0..n];
}

pub const Trigger = struct {
    token: slash.Token,
    /// `$` (skills only).
    skill: bool,
    include_skills: bool,
    commands_allowed: bool,
};

/// `completion_trigger`: `$skill` when dollar completion is on, else `/`.
pub fn completionTrigger(text: []const u8, cursor: usize, dollar: bool, separate_from_slash: bool) ?Trigger {
    if (dollar) if (slash.invocationToken(text, cursor, '$')) |t| return .{ .token = t, .skill = true, .include_skills = true, .commands_allowed = false };
    const t = slash.slashToken(text, cursor) orelse return null;
    return .{ .token = t, .skill = false, .include_skills = !separate_from_slash, .commands_allowed = true };
}

/// `invocation_insertion`.
pub fn insertion(gpa: Allocator, inv: Invocation, references_supported: bool) ![]u8 {
    if (!references_supported and inv == .command) {
        const t = try inv.promptText(gpa);
        defer gpa.free(t);
        return std.fmt.allocPrint(gpa, "{s} ", .{t});
    }
    const l = try inv.link(gpa);
    defer gpa.free(l);
    return std.fmt.allocPrint(gpa, "{s} ", .{l});
}

/// `FileSearchMatch`.
pub const FileMatch = struct { path: []const u8, isDir: bool = false };

const testing = std.testing;

test "invocation links hex-encode serde json" {
    const a = testing.allocator;
    const l = try (Invocation{ .command = .{ .name = "review" } }).link(a);
    defer a.free(l);
    var expect: std.Io.Writer.Allocating = .init(a);
    defer expect.deinit();
    try expect.writer.writeAll("[/review](zeron-invoke:");
    for ("{\"kind\":\"command\",\"name\":\"review\"}") |b| try expect.writer.print("{x:0>2}", .{b});
    try expect.writer.writeAll(")");
    try testing.expectEqualStrings(expect.written(), l);
    const p = try (Invocation{ .skill = .{ .name = "pdf", .path = "/sk ills/pdf/SKILL.md" } }).promptText(a);
    defer a.free(p);
    try testing.expectEqualStrings("[$pdf](/sk%20ills/pdf/SKILL.md)", p);
}

test "candidates drop skill aliases and invalid names; workspace commands rename on clash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmds = [_]SlashCommand{ .{ .name = "review", .description = "Review" }, .{ .name = "pdf" }, .{ .name = "bad name" }, .{ .name = "settings" } };
    const skills = [_]Skill{ .{ .name = "pdf", .path = "/s/pdf.md", .description = "PDF", .command = .{ .name = "pdf", .harness = "claude-code" } }, .{ .name = "off", .path = "/s/off.md", .enabled = false } };
    const rows = try invocationCandidates(a, &cmds, &skills);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("review", rows[0].name);
    try testing.expectEqualStrings("settings", rows[1].name);
    try testing.expect(rows[2].invocation == .skill);
    const all = try withWorkspaceCommands(a, rows, false);
    var found = false;
    for (all) |r| if (r.workspace == .settings) {
        try testing.expectEqualStrings("zeron:settings", r.name);
        found = true;
    };
    try testing.expect(found);
    var buf: [32]usize = undefined;
    const hits = filter("re", all, &buf);
    try testing.expectEqualStrings("review", all[hits[0]].name);
}

test "completion triggers" {
    try testing.expect(completionTrigger("$pd", 3, true, true).?.skill);
    try testing.expect(completionTrigger("$pd", 3, false, true) == null);
    const t = completionTrigger("/re", 3, false, false).?;
    try testing.expect(t.include_skills and t.commands_allowed);
}
