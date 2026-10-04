//! Project artwork for sidebar rows (zeron `shell/project_icon.rs`): the
//! first of a fixed list of favicon/app-icon paths found in the project's
//! checkout root (the nearest ancestor with `.git`), resolved once per
//! project off the render thread; the monogram badge stands in until (and
//! unless) artwork lands. PNG/SVG bytes feed the image cache; `.ico` files
//! contribute their embedded PNG frame.
//! Remote projects keep the monogram (their files ride the workspace-files
//! RPC, not ported here).

const std = @import("std");
const zpui = @import("zpui");

/// `ICON_PATHS`, in priority order.
pub const icon_paths = [_][]const u8{
    "public/apple-touch-icon.png",
    "apple-touch-icon.png",
    "public/favicon.svg",
    "favicon.svg",
    "public/favicon.png",
    "public/icon.png",
    "public/logo.png",
    "favicon.png",
    "app/icon.png",
    "src/app/icon.png",
    "public/favicon.ico",
    "favicon.ico",
    "app/favicon.ico",
    "static/favicon.ico",
    "src-tauri/icons/icon.png",
    "assets/icon.png",
    "src/assets/icon.png",
};

/// `MAX_WORKSPACE_IMAGE_BYTES`.
pub const max_bytes: usize = 8 << 20;

/// Encoded PNG/SVG bytes (owned).
pub const Artwork = struct {
    bytes: []u8,

    pub fn deinit(self: Artwork, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }

    pub fn source(self: Artwork) zpui.ImageSource {
        return .{ .image = .fromBytes(self.bytes) };
    }
};

const png_sig = "\x89PNG\r\n\x1a\n";

/// The largest PNG-encoded frame of an ICO container (modern favicons embed
/// PNG; legacy BMP frames are skipped).
pub fn icoPngFrame(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 6 or std.mem.readInt(u16, bytes[0..2], .little) != 0 or std.mem.readInt(u16, bytes[2..4], .little) != 1) return null;
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    var best: ?[]const u8 = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const at = 6 + i * 16;
        if (at + 16 > bytes.len) break;
        const size = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little);
        const offset = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little);
        if (offset >= bytes.len or size > bytes.len - offset) continue;
        const frame = bytes[offset..][0..size];
        if (!std.mem.startsWith(u8, frame, png_sig)) continue;
        if (best == null or frame.len > best.?.len) best = frame;
    }
    return best;
}

/// The checkout root: the nearest ancestor holding `.git` (a dir or a
/// linked worktree's file), else `dir` itself.
fn checkoutRoot(io: std.Io, a: std.mem.Allocator, dir: []const u8) []const u8 {
    var cur: ?[]const u8 = dir;
    while (cur) |d| : (cur = std.fs.path.dirname(d)) {
        const git = std.fs.path.join(a, &.{ d, ".git" }) catch return dir;
        if (std.Io.Dir.cwd().access(io, git, .{})) |_| return d else |_| {}
    }
    return dir;
}

/// Resolve the artwork for a project folder (blocking; run on a worker).
pub fn load(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8) ?Artwork {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = checkoutRoot(io, a, project_dir);
    for (icon_paths) |rel| {
        const full = std.fs.path.join(a, &.{ root, rel }) catch return null;
        const stat = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        if (stat.kind != .file) continue;
        // The first match decides (a corrupt top pick never falls through to
        // unrelated lower-priority art).
        if (stat.size > max_bytes) return null;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(max_bytes)) catch return null;
        if (std.mem.endsWith(u8, rel, ".ico")) {
            const frame = icoPngFrame(bytes) orelse return null;
            return .{ .bytes = gpa.dupe(u8, frame) catch return null };
        }
        return .{ .bytes = gpa.dupe(u8, bytes) catch return null };
    }
    return null;
}

/// Worker job: `Sidebar` spawns one per project path.
pub const LoadJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Owned; handed back in the result as the cache key.
    dir: []u8,

    pub const Result = struct { dir: []u8, art: ?Artwork };

    pub fn run(self: *LoadJob) Result {
        const dir = self.dir;
        self.dir = &.{}; // moved into the result
        return .{ .dir = dir, .art = load(self.gpa, self.io, dir) };
    }

    /// A job dropped before it ran (app shutdown) still owns its path.
    pub fn deinit(self: *LoadJob) void {
        if (self.dir.len > 0) self.gpa.free(self.dir);
        self.dir = &.{};
    }

    pub fn discard(self: *LoadJob, r: Result) void {
        if (r.art) |a| a.deinit(self.gpa);
        self.gpa.free(r.dir);
    }
};

pub const Entry = union(enum) { loading, none, ready: Artwork };

/// Per-project artwork cache (keys: project paths, owned).
pub const Cache = struct {
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .ready) e.value_ptr.ready.deinit(gpa);
            gpa.free(e.key_ptr.*);
        }
        self.map.deinit(gpa);
    }

    /// The artwork for `dir`; true in `start` when a load must be spawned.
    pub fn get(self: *Cache, gpa: std.mem.Allocator, dir: []const u8, start: *bool) ?Artwork {
        start.* = false;
        if (self.map.get(dir)) |e| return if (e == .ready) e.ready else null;
        const key = gpa.dupe(u8, dir) catch return null;
        self.map.put(gpa, key, .loading) catch {
            gpa.free(key);
            return null;
        };
        start.* = true;
        return null;
    }

    pub fn finish(self: *Cache, gpa: std.mem.Allocator, r: LoadJob.Result) void {
        defer gpa.free(r.dir);
        const slot = self.map.getPtr(r.dir) orelse {
            if (r.art) |a| a.deinit(gpa);
            return;
        };
        slot.* = if (r.art) |a| .{ .ready = a } else .none;
    }
};

test "ico frames: the largest embedded PNG wins, BMP frames are skipped" {
    var buf: [6 + 3 * 16 + 40]u8 = @splat(0);
    std.mem.writeInt(u16, buf[2..4], 1, .little);
    std.mem.writeInt(u16, buf[4..6], 3, .little);
    const data_at: u32 = 6 + 3 * 16;
    // Frame 0: BMP (no PNG signature), 8 bytes.
    std.mem.writeInt(u32, buf[6 + 8 ..][0..4], 8, .little);
    std.mem.writeInt(u32, buf[6 + 12 ..][0..4], data_at, .little);
    // Frame 1: PNG, 12 bytes.
    std.mem.writeInt(u32, buf[22 + 8 ..][0..4], 12, .little);
    std.mem.writeInt(u32, buf[22 + 12 ..][0..4], data_at + 8, .little);
    @memcpy(buf[data_at + 8 ..][0..8], png_sig);
    // Frame 2: PNG, 20 bytes.
    std.mem.writeInt(u32, buf[38 + 8 ..][0..4], 20, .little);
    std.mem.writeInt(u32, buf[38 + 12 ..][0..4], data_at + 20, .little);
    @memcpy(buf[data_at + 20 ..][0..8], png_sig);
    const frame = icoPngFrame(&buf).?;
    try std.testing.expectEqual(@as(usize, 20), frame.len);
    try std.testing.expect(icoPngFrame("not an ico") == null);
}

test "cache: first lookup schedules, results land once" {
    const gpa = std.testing.allocator;
    var c: Cache = .{};
    defer c.deinit(gpa);
    var start = false;
    try std.testing.expect(c.get(gpa, "/p/a", &start) == null);
    try std.testing.expect(start);
    try std.testing.expect(c.get(gpa, "/p/a", &start) == null);
    try std.testing.expect(!start);
    c.finish(gpa, .{ .dir = try gpa.dupe(u8, "/p/a"), .art = .{ .bytes = try gpa.dupe(u8, "<svg/>") } });
    const art = c.get(gpa, "/p/a", &start).?;
    try std.testing.expectEqualStrings("<svg/>", art.bytes);
}
