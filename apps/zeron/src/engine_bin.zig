//! Finds the zeron engine binary (`zeron headless` is spawned when nothing
//! answers on `ZERON_IPC_PORT`). This client is also named `zeron`, so every
//! candidate that resolves (through symlinks) to our own executable is
//! skipped — otherwise we would spawn ourselves.
//!
//! Order:
//!   1. `$ZERON_BIN` (taken as is)
//!   2. next to this executable: `zeron-engine`, then `zeron`
//!      (inside a macOS bundle that is `Zeron.app/Contents/MacOS/`; packagers
//!      drop the engine there as `zeron-engine`), and
//!      `../Resources/bin/zeron` (bundle resources)
//!   3. every `$PATH` entry: `zeron-engine`, then `zeron`
//!   4. well-known install locations, since a Finder/launcher-started app
//!      gets a minimal PATH: `~/.zeron/app/current/zeron` (the Rust
//!      installer layout), `~/.local/bin/zeron`, `/opt/homebrew/bin/zeron`,
//!      `/usr/local/bin/zeron`, and on macOS
//!      `/Applications/Zeron.app/Contents/MacOS/zeron`
//!   5. plain `zeron` (spawn resolves it via PATH; fails with a clear error)

const std = @import("std");
const builtin = @import("builtin");

pub fn resolve(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) []const u8 {
    if (environ.get("ZERON_BIN")) |b| return b;
    const exe = std.process.executablePathAlloc(io, arena) catch return "zeron";
    const self_real = std.Io.Dir.realPathFileAbsoluteAlloc(io, exe, arena) catch exe;
    const list = candidates(arena, std.fs.path.dirname(exe) orelse ".", environ.get("PATH") orelse "", environ.get("HOME"), builtin.os.tag) catch return "zeron";
    for (list) |c| {
        const real = std.Io.Dir.realPathFileAbsoluteAlloc(io, c, arena) catch continue; // missing
        if (std.mem.eql(u8, real, self_real)) continue; // that's us
        std.Io.Dir.accessAbsolute(io, c, .{ .execute = true }) catch continue;
        return c;
    }
    return "zeron";
}

/// Absolute candidate paths in lookup order (steps 2–4 above).
pub fn candidates(
    arena: std.mem.Allocator,
    exe_dir: []const u8,
    path_env: []const u8,
    home: ?[]const u8,
    os: std.Target.Os.Tag,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const j = std.fs.path.join;
    try out.append(arena, try j(arena, &.{ exe_dir, "zeron-engine" }));
    try out.append(arena, try j(arena, &.{ exe_dir, "zeron" }));
    try out.append(arena, try j(arena, &.{ exe_dir, "..", "Resources", "bin", "zeron" }));
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        try out.append(arena, try j(arena, &.{ dir, "zeron-engine" }));
        try out.append(arena, try j(arena, &.{ dir, "zeron" }));
    }
    if (home) |h| {
        try out.append(arena, try j(arena, &.{ h, ".zeron", "app", "current", "zeron" }));
        try out.append(arena, try j(arena, &.{ h, ".local", "bin", "zeron" }));
    }
    try out.append(arena, "/opt/homebrew/bin/zeron");
    try out.append(arena, "/usr/local/bin/zeron");
    if (os == .macos) try out.append(arena, "/Applications/Zeron.app/Contents/MacOS/zeron");
    return out.items;
}

test "candidate order: bundle siblings, PATH, install locations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try candidates(arena_state.allocator(), "/Applications/Zeron.app/Contents/MacOS", "/usr/bin:rel:/bin", "/Users/me", .macos);
    const want = [_][]const u8{
        "/Applications/Zeron.app/Contents/MacOS/zeron-engine",
        "/Applications/Zeron.app/Contents/MacOS/zeron",
        "/Applications/Zeron.app/Contents/MacOS/../Resources/bin/zeron",
        "/usr/bin/zeron-engine",
        "/usr/bin/zeron",
        "/bin/zeron-engine",
        "/bin/zeron",
        "/Users/me/.zeron/app/current/zeron",
        "/Users/me/.local/bin/zeron",
        "/opt/homebrew/bin/zeron",
        "/usr/local/bin/zeron",
        "/Applications/Zeron.app/Contents/MacOS/zeron",
    };
    try std.testing.expectEqual(want.len, list.len);
    for (want, list) |w, l| try std.testing.expectEqualStrings(w, l);
}

test "resolve skips our own executable" {
    // The test binary is not named zeron; resolve must still return something
    // usable (ZERON_BIN wins when set).
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZERON_BIN", "/x/zeron");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("/x/zeron", resolve(arena_state.allocator(), std.testing.io, &env));
}
