//! Release checking and self-update for the Zig desktop client — a port of zeron
//! `crates/update/src/lib.rs` (the desktop half: manifest fetch with the `latest.txt`
//! fallback, strict version compare, install-kind detection, download + sha256
//! verification through a `.partial` sidecar, staging with a `--version` check, the
//! managed symlink swap / macOS bundle swap, and the detached relauncher).
//!
//! Release layout (identical to Rust's, so the same feed format serves both):
//! `{base}/manifest.json` = `{"version":"0.2.103","files":{"<artifact>":{"sha256":"…"}}}`
//! (`latest.txt` — the bare version — is the pre-manifest fallback, downloaded without
//! checksum verification, with a log line, exactly as Rust). Artifacts:
//! `zeron-<ver>-linux-<arch>.tar.gz` (the Linux tarball `zig build zeron-dist` makes:
//! one top-level directory holding `zeron`) and `zeron-<ver>-macos-<arm64|x86_64>-app.tar.gz`
//! (`Zeron.app` at the root; `zig build zeron-app-bundle` makes it). Rust verifies only
//! the manifest sha256 (no signatures); so does this port.
//!
//! The feed: `ZERON_RELEASES_URL`, else the build's `-Dzeron-releases-url=`. Zig builds
//! are not published yet, so the default is empty — the checker is off and the app
//! never offers an update until a feed is configured. Like Rust the override must be an
//! `https://` base URL without credentials, query or fragment; `http://` is accepted
//! only for loopback hosts (local testing).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const c = std.c;

const log = std.log.scoped(.zeron_update);

/// Rust `RELEASES_PAGE` / `LATEST_RELEASE_PAGE`.
pub const releases_page = "https://github.com/zeronsh/zeron/releases";
pub const latest_release_page = "https://github.com/zeronsh/zeron/releases/latest";

pub const metadata_max_bytes = 1024 * 1024;

// ---------------------------------------------------------------------------------------
// Versions + artifacts
// ---------------------------------------------------------------------------------------

/// Rust `parse_version`: dotted numerics, optional leading `v`.
fn parseVersion(v: []const u8, out: *[8]u64) ?[]const u64 {
    var t = std.mem.trim(u8, v, " \t\r\n");
    while (t.len > 0 and t[0] == 'v') t = t[1..];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, '.');
    while (it.next()) |part| {
        if (n == out.len) return null;
        out[n] = std.fmt.parseInt(u64, part, 10) catch return null;
        n += 1;
    }
    return if (n == 0) null else out[0..n];
}

pub fn validVersion(v: []const u8) bool {
    var buf: [8]u64 = undefined;
    return parseVersion(v, &buf) != null;
}

/// Strictly-newer dotted-numeric compare (`0.1.10` > `0.1.9` > `0.1`); unparseable
/// versions never count as newer (Rust `version_newer`, Vec lexicographic order).
pub fn versionNewer(latest: []const u8, current: []const u8) bool {
    var lb: [8]u64 = undefined;
    var cb: [8]u64 = undefined;
    const l = parseVersion(latest, &lb) orelse return false;
    const cur = parseVersion(current, &cb) orelse return false;
    return std.mem.order(u64, l, cur) == .gt;
}

/// Artifact-name platform pair matching the packaging scripts (`macos`/`aarch64` →
/// `arm64`, like Rust's `platform_key`).
pub fn platformKey() struct { []const u8, []const u8 } {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
    const arch = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) "arm64" else @tagName(builtin.cpu.arch);
    return .{ os, arch };
}

/// `zeron-<ver>-<os>-<arch>.tar.gz` (the Linux tarball).
pub fn headlessArtifact(buf: []u8, version: []const u8) []const u8 {
    const os, const arch = platformKey();
    return std.fmt.bufPrint(buf, "zeron-{s}-{s}-{s}.tar.gz", .{ version, os, arch }) catch "";
}

/// `zeron-<ver>-macos-<arch>-app.tar.gz`.
pub fn macAppArtifact(buf: []u8, version: []const u8) []const u8 {
    _, const arch = platformKey();
    return std.fmt.bufPrint(buf, "zeron-{s}-macos-{s}-app.tar.gz", .{ version, arch }) catch "";
}

// ---------------------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------------------

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    version: []const u8,
    /// artifact name → lowercase/uppercase hex sha256 (null = none).
    files: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    pub fn sha256(self: *const Manifest, file: []const u8) ?[]const u8 {
        return self.files.get(file) orelse null;
    }
};

/// Parse `manifest.json` (serde: `version` required, `files` default empty, extra
/// fields ignored).
pub fn parseManifest(gpa: Allocator, bytes: []const u8) !Manifest {
    var m: Manifest = .{ .arena = .init(gpa), .version = "" };
    errdefer m.deinit();
    const a = m.arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (root != .object) return error.BadManifest;
    const v = root.object.get("version") orelse return error.BadManifest;
    if (v != .string) return error.BadManifest;
    if (std.mem.trim(u8, v.string, " \t\r\n").len == 0) return error.EmptyVersion;
    m.version = v.string;
    if (root.object.get("files")) |files| {
        if (files != .object) return error.BadManifest;
        var it = files.object.iterator();
        while (it.next()) |e| {
            var hash: ?[]const u8 = null;
            if (e.value_ptr.* == .object) if (e.value_ptr.object.get("sha256")) |h| {
                if (h == .string) hash = h.string;
            };
            try m.files.put(a, e.key_ptr.*, hash);
        }
    }
    return m;
}

/// A version-only manifest (the `latest.txt` fallback).
pub fn manifestFromLatestTxt(gpa: Allocator, bytes: []const u8) !Manifest {
    var m: Manifest = .{ .arena = .init(gpa), .version = "" };
    errdefer m.deinit();
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.BadLatestTxt;
    const v = std.mem.trim(u8, bytes, " \t\r\n");
    if (v.len == 0) return error.EmptyVersion;
    m.version = try m.arena.allocator().dupe(u8, v);
    return m;
}

// ---------------------------------------------------------------------------------------
// Feed
// ---------------------------------------------------------------------------------------

/// Validate an override base URL (Rust `validate_release_override`, plus loopback http).
pub fn validateReleaseBase(buf: []u8, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const uri = std.Uri.parse(trimmed) catch return error.InvalidUpdateFeedUrl;
    const host_c = uri.host orelse return error.InvalidUpdateFeedUrl;
    var host_buf: [256]u8 = undefined;
    const host = host_c.toRaw(&host_buf) catch return error.InvalidUpdateFeedUrl;
    if (host.len == 0) return error.InvalidUpdateFeedUrl;
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const loopback = std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "[::1]");
    if (!https and !(std.ascii.eqlIgnoreCase(uri.scheme, "http") and loopback)) return error.UpdateFeedMustUseHttps;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.UpdateFeedHasCredentialsQueryOrFragment;
    const out = std.mem.trimEnd(u8, trimmed, "/");
    if (out.len > buf.len) return error.InvalidUpdateFeedUrl;
    @memcpy(buf[0..out.len], out);
    return buf[0..out.len];
}

pub const Http = struct {
    gpa: Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map = null,

    /// GET `url` into `sink` (enforcing `sink.limit`); returns the HTTP status.
    pub fn get(self: Http, url: []const u8, sink: *Sink) !std.http.Status {
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        var proxy_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer proxy_arena.deinit();
        if (self.environ) |env| client.initDefaultProxies(proxy_arena.allocator(), env) catch {};
        var ua_buf: [64]u8 = undefined;
        const ua = std.fmt.bufPrint(&ua_buf, "zeron/{s}", .{currentVersion()}) catch "zeron";
        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &sink.interface,
            .headers = .{ .user_agent = .{ .override = ua } },
            // Intermediaries must revalidate (Rust: a stale manifest = a late prompt).
            .extra_headers = &.{.{ .name = "cache-control", .value = "no-cache" }},
            .keep_alive = false,
        }) catch |err| {
            if (sink.failure) |f| return f;
            return err;
        };
        sink.interface.flush() catch return sink.failure orelse error.WriteFailed;
        if (sink.failure) |f| return f;
        return result.status;
    }
};

/// Writer that hashes everything, enforces a byte limit, and appends to memory or
/// writes to a file descriptor.
pub const Sink = struct {
    interface: Io.Writer,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    total: u64 = 0,
    limit: u64,
    mem: ?*std.ArrayList(u8) = null,
    gpa: Allocator,
    fd: c.fd_t = -1,
    failure: ?anyerror = null,

    pub fn init(gpa: Allocator, buffer: []u8, limit: u64) Sink {
        return .{ .interface = .{ .vtable = &vtable, .buffer = buffer }, .limit = limit, .gpa = gpa };
    }

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn consume(self: *Sink, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (self.total + bytes.len > self.limit) {
            self.failure = error.ResponseTooLarge;
            return error.WriteFailed;
        }
        self.total += bytes.len;
        self.hasher.update(bytes);
        if (self.mem) |m| m.appendSlice(self.gpa, bytes) catch {
            self.failure = error.OutOfMemory;
            return error.WriteFailed;
        };
        if (self.fd >= 0) {
            var off: usize = 0;
            while (off < bytes.len) {
                const n = c.write(self.fd, bytes[off..].ptr, bytes.len - off);
                if (n <= 0) {
                    self.failure = error.DiskWriteFailed;
                    return error.WriteFailed;
                }
                off += @intCast(n);
            }
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        try self.consume(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.consume(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.consume(last);
            n += last.len;
        }
        return n;
    }

    pub fn hexDigest(self: *Sink) [64]u8 {
        var digest: [32]u8 = undefined;
        self.hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }
};

fn fetchSmall(http: Http, url: []const u8, out: *std.ArrayList(u8)) !std.http.Status {
    var buf: [4096]u8 = undefined;
    var sink: Sink = .init(http.gpa, &buf, metadata_max_bytes);
    sink.mem = out;
    return http.get(url, &sink);
}

/// Rust `fetch_latest`: `manifest.json`, falling back to `latest.txt`.
pub fn fetchLatest(http: Http, base: []const u8) !Manifest {
    var url_buf: [2048]u8 = undefined;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(http.gpa);
    const manifest_url = try std.fmt.bufPrint(&url_buf, "{s}/manifest.json", .{base});
    if (fetchSmall(http, manifest_url, &body)) |status| {
        if (status.class() == .success) return parseManifest(http.gpa, body.items);
        log.debug("manifest.json unavailable (HTTP {d}); trying latest.txt", .{@intFromEnum(status)});
    } else |err| log.debug("manifest.json fetch failed: {t}; trying latest.txt", .{err});
    body.clearRetainingCapacity();
    const latest_url = try std.fmt.bufPrint(&url_buf, "{s}/latest.txt", .{base});
    const status = try fetchSmall(http, latest_url, &body);
    if (status.class() != .success) return error.LatestTxtUnavailable;
    return manifestFromLatestTxt(http.gpa, body.items);
}

/// Rust `download_release_file`: stream `{base}/<file>` to `dest` through
/// `dest.partial`, verifying the manifest sha256 when present.
pub fn downloadReleaseFile(http: Http, base: []const u8, manifest: *const Manifest, file: []const u8, dest: [:0]const u8) !void {
    var url_buf: [2048]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ base, file });
    const expected = manifest.sha256(file);
    if (expected == null) log.warn("no checksum in release metadata for {s}; skipping verification", .{file});
    var partial_buf: [std.fs.max_path_bytes]u8 = undefined;
    const partial = try std.fmt.bufPrintSentinel(&partial_buf, "{s}.partial", .{dest}, 0);
    const fd = c.open(partial, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.CreateFailed;
    var buf: [64 * 1024]u8 = undefined;
    var sink: Sink = .init(http.gpa, &buf, std.math.maxInt(u64));
    sink.fd = fd;
    const status = http.get(url, &sink) catch |err| {
        _ = c.close(fd);
        _ = c.unlink(partial);
        return err;
    };
    _ = c.close(fd);
    if (status.class() != .success) {
        _ = c.unlink(partial);
        log.warn("downloading {s}: HTTP {d}", .{ url, @intFromEnum(status) });
        return error.DownloadFailed;
    }
    if (expected) |want| {
        const got = sink.hexDigest();
        if (!std.ascii.eqlIgnoreCase(&got, std.mem.trim(u8, want, " \t\r\n"))) {
            _ = c.unlink(partial);
            log.warn("checksum mismatch for {s}: expected {s}, got {s}", .{ file, want, &got });
            return error.ChecksumMismatch;
        }
    }
    if (c.rename(partial, dest) != 0) return error.RenameFailed;
}

// ---------------------------------------------------------------------------------------
// Install kinds
// ---------------------------------------------------------------------------------------

pub const InstallKind = union(enum) {
    /// `~/.zeron/app/<ver>/zeron` behind the `current` symlink.
    managed: []const u8,
    /// Running out of `<bundle>.app/Contents/MacOS/`.
    mac_app: []const u8,
    /// Source build / hand-copied binary — report only.
    unmanaged,

    /// Rust `supports_desktop_update`.
    pub fn supportsDesktopUpdate(self: InstallKind) bool {
        return switch (self) {
            .mac_app => true,
            .managed => builtin.os.tag == .linux,
            .unmanaged => false,
        };
    }
};

pub const Blocker = union(enum) {
    translocated,
    disk_image,
    not_writable: []const u8,

    /// Rust `impl Display for UpdateBlocker`.
    pub fn message(self: Blocker, buf: []u8) []const u8 {
        return switch (self) {
            .translocated, .disk_image => "Zeron is running from a temporary, read-only location. Move Zeron to your Applications folder and reopen it to turn on updates.",
            .not_writable => |dir| std.fmt.bufPrint(buf, "Zeron doesn't have permission to replace itself in {s}.", .{dir}) catch "Zeron doesn't have permission to replace itself.",
        };
    }
};

/// Rust `detect_install_from` (paths are slices of `exe` / owned by `arena`).
pub fn detectInstallFrom(arena: Allocator, exe: []const u8, home: ?[]const u8) InstallKind {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return .unmanaged;
    if (home) |h| {
        const app_root = std.fs.path.join(arena, &.{ h, ".zeron", "app" }) catch return .unmanaged;
        if (pathStartsWith(exe, app_root)) return .{ .managed = app_root };
    }
    var dir: ?[]const u8 = std.fs.path.dirname(exe);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        if (std.mem.endsWith(u8, d, ".app")) {
            const macos_dir = std.fs.path.join(arena, &.{ d, "Contents", "MacOS" }) catch return .unmanaged;
            if (pathStartsWith(exe, macos_dir)) return .{ .mac_app = d };
        }
    }
    return .unmanaged;
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// Rust `desktop_update_blocker`.
pub fn blockerFor(kind: InstallKind) ?Blocker {
    return switch (kind) {
        .mac_app => |bundle| blk: {
            var it = std.mem.splitScalar(u8, bundle, '/');
            while (it.next()) |part| if (std.mem.eql(u8, part, "AppTranslocation")) break :blk .translocated;
            const parent = std.fs.path.dirname(bundle) orelse break :blk null;
            if (dirWritable(parent)) break :blk null;
            if (std.mem.startsWith(u8, bundle, "/Volumes")) break :blk .disk_image;
            break :blk .{ .not_writable = parent };
        },
        .managed => |root| if (dirWritable(root)) null else .{ .not_writable = root },
        .unmanaged => null,
    };
}

/// Probe by creating (and removing) a file.
pub fn dirWritable(dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const probe = std.fmt.bufPrintSentinel(&buf, "{s}/.zeron-write-probe-{d}", .{ dir, c.getpid() }, 0) catch return false;
    const fd = c.open(probe, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) {
        if (c._errno().* == @intFromEnum(c.E.EXIST)) {
            _ = c.unlink(probe);
            return true;
        }
        return false;
    }
    _ = c.close(fd);
    _ = c.unlink(probe);
    return true;
}

// ---------------------------------------------------------------------------------------
// Staging + applying
// ---------------------------------------------------------------------------------------

/// The version compiled into this binary.
pub fn currentVersion() []const u8 {
    return @import("build_info.zig").version;
}

fn exists(p: [:0]const u8) bool {
    return c.access(p, c.F_OK) == 0;
}

fn rmTree(gpa: Allocator, io: Io, p: []const u8) void {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "rm", "-rf", p } }) catch return;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

fn mkdirP(gpa: Allocator, io: Io, p: []const u8) !void {
    try run(gpa, io, &.{ "mkdir", "-p", p }, 30);
}

/// Run `argv`; error unless it exits 0 within `timeout_s`.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, timeout_s: i64) !void {
    const r = try std.process.run(gpa, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!r.term.success()) {
        log.warn("{s} failed: {s}", .{ argv[0], std.mem.trim(u8, r.stderr, " \n") });
        return error.CommandFailed;
    }
}

/// Rust `verify_staged_binary`: `<binary> --version` must print `zeron <version>`.
pub fn verifyStagedBinary(gpa: Allocator, io: Io, binary: []const u8, version: []const u8) !void {
    const r = try std.process.run(gpa, io, .{
        .argv = &.{ binary, "--version" },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
        .stdout_limit = .limited(4096),
    });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    var want_buf: [128]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "zeron {s}", .{version});
    const reported = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (!r.term.success() or !std.mem.eql(u8, reported, want)) {
        log.warn("staged binary reported \"{s}\", expected \"{s}\"", .{ reported, want });
        return error.StagedBinaryVersionMismatch;
    }
}

/// Rust `stage_headless`: download + unpack the tarball into `app_root/<ver>`
/// (idempotent). Returns the versioned directory (owned).
pub fn stageHeadless(gpa: Allocator, io: Io, http: Http, base: []const u8, manifest: *const Manifest, app_root: []const u8) ![]u8 {
    const version = manifest.version;
    if (!validVersion(version)) return error.InvalidReleaseVersion;
    const dest_z = try std.fs.path.joinZ(gpa, &.{ app_root, version });
    defer gpa.free(dest_z);
    const dest: [:0]const u8 = dest_z;
    var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (exists(try std.fmt.bufPrintSentinel(&probe_buf, "{s}/zeron", .{dest}, 0))) return gpa.dupe(u8, dest);
    var name_buf: [256]u8 = undefined;
    const file = headlessArtifact(&name_buf, version);
    var stage_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stage = try std.fmt.bufPrint(&stage_buf, "{s}/.stage-{s}-{d}", .{ app_root, version, c.getpid() });
    rmTree(gpa, io, stage);
    try mkdirP(gpa, io, stage);
    defer rmTree(gpa, io, stage);
    var tar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tarball = try std.fmt.bufPrintSentinel(&tar_buf, "{s}/{s}", .{ stage, file }, 0);
    try downloadReleaseFile(http, base, manifest, file, tarball);
    var unpacked_buf: [std.fs.max_path_bytes]u8 = undefined;
    const unpacked = try std.fmt.bufPrintSentinel(&unpacked_buf, "{s}/unpacked", .{stage}, 0);
    try mkdirP(gpa, io, unpacked);
    // Tarball root is the versioned stage dir; strip it like install.sh.
    try run(gpa, io, &.{ "tar", "-xzf", tarball, "-C", unpacked, "--strip-components=1" }, 300);
    var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin = try std.fmt.bufPrintSentinel(&bin_buf, "{s}/zeron", .{unpacked}, 0);
    if (!exists(bin)) return error.TarballHasNoZeronBinary;
    try verifyStagedBinary(gpa, io, bin, version);
    if (c.rename(unpacked, dest) != 0) {
        // Lost a race with another stager — the staged copy is equivalent.
        if (!exists(try std.fmt.bufPrintSentinel(&probe_buf, "{s}/zeron", .{dest}, 0))) return error.RenameFailed;
    }
    return gpa.dupe(u8, dest);
}

/// Rust `apply_headless`: atomically repoint `app_root/current` at `app_root/<ver>`.
pub fn applyHeadless(app_root: []const u8, version: []const u8) !void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/{s}", .{ app_root, version }, 0);
    var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (!exists(try std.fmt.bufPrintSentinel(&bin_buf, "{s}/zeron", .{target}, 0))) return error.NotAStagedInstall;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}/.current-{d}", .{ app_root, c.getpid() }, 0);
    _ = c.unlink(tmp);
    if (c.symlink(target, tmp) != 0) return error.SymlinkFailed;
    var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current = try std.fmt.bufPrintSentinel(&cur_buf, "{s}/current", .{app_root}, 0);
    if (c.rename(tmp, current) != 0) return error.SwapFailed;
}

/// Rust `stage_mac_app`: download + unpack the app tarball into
/// `{data_dir}/updates/<ver>/Zeron.app` (idempotent). Returns the staged bundle (owned).
pub fn stageMacApp(gpa: Allocator, io: Io, http: Http, base: []const u8, manifest: *const Manifest, data_dir: []const u8) ![]u8 {
    const version = manifest.version;
    if (!validVersion(version)) return error.InvalidReleaseVersion;
    const updates = try std.fs.path.join(gpa, &.{ data_dir, "updates" });
    defer gpa.free(updates);
    const dir = try std.fs.path.join(gpa, &.{ updates, version });
    defer gpa.free(dir);
    const staged = try std.fs.path.join(gpa, &.{ dir, "Zeron.app" });
    errdefer gpa.free(staged);
    const staged_bin = try std.fs.path.join(gpa, &.{ staged, "Contents", "MacOS", "zeron" });
    defer gpa.free(staged_bin);
    var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (exists(try std.fmt.bufPrintSentinel(&probe_buf, "{s}", .{staged_bin}, 0))) {
        if (verifyStagedBinary(gpa, io, staged_bin, version)) |_| return staged else |_| {}
    }
    pruneStaleStages(gpa, io, updates, version);
    rmTree(gpa, io, dir);
    try mkdirP(gpa, io, dir);
    var name_buf: [256]u8 = undefined;
    const file = macAppArtifact(&name_buf, version);
    var tar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tarball = try std.fmt.bufPrintSentinel(&tar_buf, "{s}/{s}", .{ dir, file }, 0);
    try downloadReleaseFile(http, base, manifest, file, tarball);
    const unpack = try std.fs.path.join(gpa, &.{ dir, ".unpack" });
    defer gpa.free(unpack);
    try mkdirP(gpa, io, unpack);
    const untar = run(gpa, io, &.{ "tar", "-xzf", tarball, "-C", unpack }, 300);
    _ = c.unlink(tarball);
    try untar;
    const unpacked = try std.fs.path.joinZ(gpa, &.{ unpack, "Zeron.app" });
    defer gpa.free(unpacked);
    const unpacked_bin = try std.fs.path.join(gpa, &.{ unpacked, "Contents", "MacOS", "zeron" });
    defer gpa.free(unpacked_bin);
    if (!exists(try std.fmt.bufPrintSentinel(&probe_buf, "{s}", .{unpacked_bin}, 0))) {
        rmTree(gpa, io, dir);
        return error.TarballHasNoZeronApp;
    }
    verifyStagedBinary(gpa, io, unpacked_bin, version) catch |err| {
        rmTree(gpa, io, dir);
        return err;
    };
    const staged_z = try gpa.dupeSentinel(u8, staged, 0);
    defer gpa.free(staged_z);
    if (c.rename(unpacked, staged_z) != 0) return error.RenameFailed;
    rmTree(gpa, io, unpack);
    return staged;
}

fn pruneStaleStages(gpa: Allocator, io: Io, updates: []const u8, keep: []const u8) void {
    const dz = gpa.dupeSentinel(u8, updates, 0) catch return;
    defer gpa.free(dz);
    const d = c.opendir(dz) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, keep)) continue;
        const p = std.fs.path.join(gpa, &.{ updates, name }) catch continue;
        defer gpa.free(p);
        rmTree(gpa, io, p);
    }
}

/// Rust `apply_mac_app`: `ditto` the staged bundle next to the target, then two renames
/// (the old bundle is restored if the second fails).
pub fn applyMacApp(gpa: Allocator, io: Io, staged: []const u8, bundle: []const u8) !void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const parent = std.fs.path.dirname(bundle) orelse return error.NoParent;
    const name = std.fs.path.basename(bundle);
    var fresh_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrintSentinel(&fresh_buf, "{s}/.{s}.new-{d}", .{ parent, name, c.getpid() }, 0);
    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old = try std.fmt.bufPrintSentinel(&old_buf, "{s}/.{s}.old-{d}", .{ parent, name, c.getpid() }, 0);
    rmTree(gpa, io, fresh);
    run(gpa, io, &.{ "ditto", staged, fresh }, 300) catch |err| {
        rmTree(gpa, io, fresh);
        return err;
    };
    const bundle_z = try gpa.dupeSentinel(u8, bundle, 0);
    defer gpa.free(bundle_z);
    if (c.rename(bundle_z, old) != 0) {
        rmTree(gpa, io, fresh);
        return error.MoveAsideFailed;
    }
    if (c.rename(fresh, bundle_z) != 0) {
        _ = c.rename(old, bundle_z);
        rmTree(gpa, io, fresh);
        return error.InstallFailed;
    }
    rmTree(gpa, io, old);
}

/// Rust `apply_desktop`: install `staged`; with `relaunch`, the new version starts once
/// this process exits. The caller quits after this succeeds.
pub fn applyDesktop(gpa: Allocator, io: Io, kind: InstallKind, staged: []const u8, relaunch: bool) !void {
    switch (kind) {
        .mac_app => |bundle| {
            try applyMacApp(gpa, io, staged, bundle);
            // The swap copied the staged bundle; the cache is spent.
            if (std.fs.path.dirname(staged)) |version_dir| rmTree(gpa, io, version_dir);
            if (relaunch) relaunchAfterExit(gpa, io, "/usr/bin/open", bundle);
        },
        .managed => |app_root| {
            if (!kind.supportsDesktopUpdate()) return error.Unsupported;
            const version = std.fs.path.basename(staged);
            try applyHeadless(app_root, version);
            if (relaunch) {
                var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
                const bin = try std.fmt.bufPrint(&bin_buf, "{s}/current/zeron", .{app_root});
                relaunchAfterExit(gpa, io, bin, "");
            }
        },
        .unmanaged => return error.Unsupported,
    }
}

/// Rust `relaunch_after_exit`: a detached `/bin/sh` waits for this pid to exit, then
/// execs `program [argument]` (paths travel as positional parameters).
pub fn relaunchAfterExit(gpa: Allocator, io: Io, program: []const u8, argument: []const u8) void {
    var pid_buf: [24]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{c.getpid()}) catch return;
    const script =
        \\while /bin/kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        \\if [ -n "$3" ]; then exec "$2" "$3"; else exec "$2"; fi
    ;
    // `setsid` would be ideal; a background subshell + nohup-like stdio keeps it alive
    // after we exit (the shell is reparented to init).
    const child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script, "zeron-relaunch", pid, program, argument },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        log.err("failed to spawn the relauncher: {t}", .{err});
        return;
    };
    _ = child;
    _ = gpa;
}

// ---------------------------------------------------------------------------------------
// Check schedule (Rust `Schedule`)
// ---------------------------------------------------------------------------------------

pub const check_interval_s: i64 = 60 * 60;
pub const check_retry_s = [_]i64{ 60, 5 * 60, 15 * 60, 30 * 60 };
pub const schedule_tick_s: i64 = 60;
pub const desktop_initial_delay_ms: u64 = 2000;

pub const Schedule = struct {
    /// Wall-clock seconds; null = due now.
    next_due: ?i64 = null,
    failures: usize = 0,

    pub fn due(self: Schedule, now: i64) bool {
        const d = self.next_due orelse return true;
        const remaining = d - now;
        // A deadline further out than any interval means the clock jumped backwards.
        return remaining <= 0 or remaining > check_interval_s;
    }

    pub fn record(self: *Schedule, now: i64, ok: bool) void {
        const delay = if (ok) blk: {
            self.failures = 0;
            break :blk check_interval_s;
        } else blk: {
            const d = check_retry_s[@min(self.failures, check_retry_s.len - 1)];
            self.failures +|= 1;
            break :blk d;
        };
        self.next_due = now + delay;
    }

    /// Seconds until the next look at the clock (clamped to [1, 60]).
    pub fn wait(self: Schedule, now: i64) i64 {
        const d = self.next_due orelse return 1;
        return std.math.clamp(d - now, 1, schedule_tick_s);
    }
};

/// `ZERON_AUTO_UPDATE=0|false|no` keeps the desktop app report-only.
pub fn desktopAutoUpdateEnabled(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return true, " \t");
    return !(std.ascii.eqlIgnoreCase(v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no"));
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "version_newer (Rust parity)" {
    try testing.expect(versionNewer("0.1.10", "0.1.9"));
    try testing.expect(versionNewer("0.2", "0.1.99"));
    try testing.expect(versionNewer("v1.0.0", "0.9"));
    try testing.expect(versionNewer("0.1.1", "0.1"));
    try testing.expect(!versionNewer("0.1", "0.1.0"));
    try testing.expect(!versionNewer("0.1.9", "0.1.10"));
    try testing.expect(!versionNewer("0.2.0", "0.2.0"));
    try testing.expect(!versionNewer("garbage", "0.1.0"));
    try testing.expect(!versionNewer("1.0.0", "garbage"));
    try testing.expect(!versionNewer("1..0", "0.1"));
}

test "manifest parsing matches serde (files default empty, extra fields ignored)" {
    var m = try parseManifest(testing.allocator,
        \\{"version":"0.2.103","files":{"zeron-0.2.103-linux-x86_64.tar.gz":{"sha256":"ab"},"x":{}},"notes":"hi"}
    );
    defer m.deinit();
    try testing.expectEqualStrings("0.2.103", m.version);
    try testing.expectEqualStrings("ab", m.sha256("zeron-0.2.103-linux-x86_64.tar.gz").?);
    try testing.expect(m.sha256("x") == null);
    var bare = try parseManifest(testing.allocator, "{\"version\":\"1.0\"}");
    defer bare.deinit();
    try testing.expectEqual(@as(usize, 0), bare.files.count());
    try testing.expectError(error.EmptyVersion, parseManifest(testing.allocator, "{\"version\":\"  \"}"));
    var txt = try manifestFromLatestTxt(testing.allocator, "0.3.0\n");
    defer txt.deinit();
    try testing.expectEqualStrings("0.3.0", txt.version);
    try testing.expectError(error.EmptyVersion, manifestFromLatestTxt(testing.allocator, "\n"));
}

test "release base validation" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("https://edge.example.com/releases", try validateReleaseBase(&buf, " https://edge.example.com/releases/ "));
    try testing.expectEqualStrings("http://127.0.0.1:8123", try validateReleaseBase(&buf, "http://127.0.0.1:8123/"));
    try testing.expectError(error.UpdateFeedMustUseHttps, validateReleaseBase(&buf, "http://example.com/releases"));
    try testing.expectError(error.UpdateFeedHasCredentialsQueryOrFragment, validateReleaseBase(&buf, "https://u:p@example.com/r"));
    try testing.expectError(error.UpdateFeedHasCredentialsQueryOrFragment, validateReleaseBase(&buf, "https://example.com/r?x=1"));
    try testing.expectError(error.InvalidUpdateFeedUrl, validateReleaseBase(&buf, "not a url"));
}

test "install kind detection (Rust detect_install_from)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const managed = detectInstallFrom(a, "/home/u/.zeron/app/0.2.1/zeron", "/home/u");
    try testing.expectEqualStrings("/home/u/.zeron/app", managed.managed);
    const app = detectInstallFrom(a, "/Applications/Zeron.app/Contents/MacOS/zeron", "/Users/u");
    try testing.expectEqualStrings("/Applications/Zeron.app", app.mac_app);
    try testing.expect(detectInstallFrom(a, "/home/u/src/zpui/zig-out/bin/zeron", "/home/u") == .unmanaged);
    try testing.expect(detectInstallFrom(a, "/home/u/.zeron/application/zeron", "/home/u") == .unmanaged);
    try testing.expect(detectInstallFrom(a, "/x/Foo.app/zeron", null) == .unmanaged);
    try testing.expectEqual(builtin.os.tag == .linux, managed.supportsDesktopUpdate());
    try testing.expect(app.supportsDesktopUpdate());
}

test "blocker detection" {
    try testing.expect(blockerFor(.{ .mac_app = "/private/var/folders/x/AppTranslocation/y/Zeron.app" }).? == .translocated);
    try testing.expect(blockerFor(.{ .mac_app = "/tmp/Zeron.app" }) == null);
    const b = blockerFor(.{ .mac_app = "/proc/Zeron.app" }).?;
    try testing.expectEqualStrings("/proc", b.not_writable);
    try testing.expect(blockerFor(.{ .mac_app = "/Volumes/Zeron/Zeron.app" }) != null);
}

test "check schedule backs off and re-arms (Rust Schedule)" {
    var s: Schedule = .{};
    try testing.expect(s.due(1000));
    s.record(1000, false);
    try testing.expect(!s.due(1030));
    try testing.expect(s.due(1060));
    s.record(1060, false);
    try testing.expectEqual(@as(?i64, 1060 + 300), s.next_due);
    s.record(2000, false);
    s.record(3000, false);
    s.record(4000, false);
    try testing.expectEqual(@as(?i64, 4000 + 1800), s.next_due);
    s.record(5000, true);
    try testing.expectEqual(@as(usize, 0), s.failures);
    try testing.expectEqual(@as(i64, 60), s.wait(5000));
    try testing.expectEqual(@as(i64, 1), s.wait(5000 + 3600));
    // Clock jumped backwards by more than an interval: check now.
    try testing.expect(s.due(5000 - 7200));
}

test "ZERON_AUTO_UPDATE" {
    try testing.expect(desktopAutoUpdateEnabled(null));
    try testing.expect(desktopAutoUpdateEnabled("1"));
    try testing.expect(!desktopAutoUpdateEnabled("0"));
    try testing.expect(!desktopAutoUpdateEnabled(" FALSE "));
    try testing.expect(!desktopAutoUpdateEnabled("no"));
}

test "artifact names" {
    var buf: [128]u8 = undefined;
    const os, const arch = platformKey();
    var want: [128]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "zeron-1.2.3-{s}-{s}.tar.gz", .{ os, arch }), headlessArtifact(&buf, "1.2.3"));
    try testing.expect(std.mem.endsWith(u8, macAppArtifact(&buf, "1.2.3"), "-app.tar.gz"));
}
