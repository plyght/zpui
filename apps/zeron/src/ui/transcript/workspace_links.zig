//! Inline-code file links — port of zeron `workspace_links.rs`
//! `resolve_inline_code_path`: a code span naming an existing file under a
//! local workspace root (or an absolute / `~/` path, or a bare name inside a
//! directory an earlier span named) becomes a `file://` link.

const std = @import("std");
const mdm = @import("zeron_markdown");

const icl = mdm.inline_code_links;

pub const Probe = struct {
    io: std.Io,
    roots: []const []const u8,
    home: ?[]const u8 = null,
    /// Scratch for returned strings (valid for one `linkTree` call).
    arena: std.mem.Allocator,
};

const Kind = enum { file, directory, missing };

fn kind(p: *const Probe, path: []const u8) Kind {
    const st = std.Io.Dir.cwd().statFile(p.io, path, .{}) catch return .missing;
    return switch (st.kind) {
        .file => .file,
        .directory => .directory,
        else => .missing,
    };
}

fn cleanPath(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return false;
    for (path) |c| if (c < 0x20) return false;
    return true;
}

/// Strip `#L12`, `#L12C3`, `:12`, `:12:3` anchors; returns (path, anchor).
fn splitAnchor(s: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, s, '#')) |h| {
        const frag = s[h + 1 ..];
        if (frag.len > 1 and frag[0] == 'L' and std.ascii.isDigit(frag[1])) {
            var e: usize = 1;
            while (e < frag.len and std.ascii.isDigit(frag[e])) e += 1;
            return .{ s[0..h], frag[1..e] };
        }
        return .{ s[0..h], "" };
    }
    // :line[:col]
    var end = s.len;
    var colons: usize = 0;
    while (colons < 2) {
        const c = std.mem.lastIndexOfScalar(u8, s[0..end], ':') orelse break;
        const tail = s[c + 1 .. end];
        if (tail.len == 0) break;
        for (tail) |ch| if (!std.ascii.isDigit(ch)) return .{ s[0..end], s[end..] };
        end = c;
        colons += 1;
    }
    return .{ s[0..end], s[end..] };
}

fn fileTarget(p: *const Probe, path: []const u8, anchor: []const u8) ?icl.Resolution {
    if (path.len == 0 or path[0] != '/') return null;
    return .{ .file = std.fmt.allocPrint(p.arena, "file://{s}{s}{s}", .{ path, if (anchor.len > 0 and anchor[0] != ':') ":" else "", anchor }) catch return null };
}

fn probePath(p: *const Probe, path: []const u8, anchor: []const u8) ?icl.Resolution {
    return switch (kind(p, path)) {
        .file => fileTarget(p, path, anchor),
        .directory => .{ .directory = p.arena.dupe(u8, path) catch return null },
        .missing => null,
    };
}

pub fn resolve(ctx: ?*anyopaque, span: []const u8, dirs: []const []const u8) ?icl.Resolution {
    const p: *const Probe = @ptrCast(@alignCast(ctx.?));
    if (span.len == 0 or !std.mem.eql(u8, std.mem.trim(u8, span, " \t"), span)) return null;
    if (std.mem.indexOfAny(u8, span, "\n\r ") != null) return null;
    if (std.mem.indexOf(u8, span, "://") != null or std.mem.startsWith(u8, span, "mailto:")) return null;
    const parts = splitAnchor(span);
    const decoded = std.mem.trimEnd(u8, parts[0], "/");
    const anchor = parts[1];
    if (decoded.len == 0 or !cleanPath(decoded)) return null;
    if (std.mem.startsWith(u8, decoded, "~/")) {
        const home = p.home orelse return null;
        return probePath(p, std.fs.path.join(p.arena, &.{ home, decoded[2..] }) catch return null, anchor);
    }
    if (decoded[0] == '~') return null;
    if (decoded[0] == '/') return probePath(p, decoded, anchor);
    // `scheme:` shapes are not paths.
    if (std.mem.indexOfScalar(u8, decoded, ':')) |c| if (c > 0 and std.ascii.isAlphabetic(decoded[0])) return null;
    const rel = if (std.mem.startsWith(u8, decoded, "./")) decoded[2..] else decoded;
    for (p.roots) |root| {
        const path = std.fs.path.join(p.arena, &.{ root, rel }) catch continue;
        switch (kind(p, path)) {
            .file => return fileTarget(p, path, anchor),
            .directory => return .{ .directory = path },
            .missing => {},
        }
    }
    for (dirs) |dir| {
        const path = std.fs.path.join(p.arena, &.{ dir, rel }) catch continue;
        if (kind(p, path) == .file) return fileTarget(p, path, anchor);
    }
    return null;
}

pub fn resolver(p: *Probe) icl.Resolver {
    return .{ .ctx = p, .func = resolve };
}

test "anchors split" {
    const a = splitAnchor("src/main.rs:12:3");
    try std.testing.expectEqualStrings("src/main.rs", a[0]);
    try std.testing.expectEqualStrings(":12:3", a[1]);
    const b = splitAnchor("README.md#L4");
    try std.testing.expectEqualStrings("README.md", b[0]);
}
