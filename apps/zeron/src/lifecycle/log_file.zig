//! The headed app's log file (port of zeron `apps/zeron/src/main.rs` `open_log_file` +
//! the tracing file layer + `panic::set_hook`).
//!
//! `{data_dir}/logs/zeron-headed.log`, one file per launch, the previous launch kept as
//! `zeron-headed.log.old`. The file holds an exclusive `flock` for the process lifetime:
//! a launch that finds the canonical file locked (another live instance) logs to
//! `zeron-headed.<pid>.log` instead of rotating a live writer's file away, and the next
//! lock-holding launch sweeps pid-suffixed files older than a week.
//!
//! `logFn` mirrors every `std.log` line to stderr (std's default) and the file. The
//! level defaults to `info` like zeron's `EnvFilter` default; `ZERON_LOG=debug|info|
//! warn|err` overrides it. `panic` writes the message (and return address) into the
//! file before std's default panic handler prints the trace.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// The open log file (-1 = none). Written with O_APPEND, one `write` per line.
var log_fd: std.atomic.Value(c.fd_t) = .init(-1);
var min_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.info));
/// The path actually in use (for "where are the logs" messages).
var path_buf: [std.fs.max_path_bytes]u8 = undefined;
var path_len: usize = 0;

pub fn path() ?[]const u8 {
    return if (path_len == 0) null else path_buf[0..path_len];
}

/// Apply `ZERON_LOG` (call early in `main`).
pub fn setLevelFromEnv(value: ?[]const u8) void {
    const v = value orelse return;
    const lvl: ?std.log.Level = if (std.ascii.eqlIgnoreCase(v, "debug") or std.ascii.eqlIgnoreCase(v, "trace"))
        .debug
    else if (std.ascii.eqlIgnoreCase(v, "info"))
        .info
    else if (std.ascii.eqlIgnoreCase(v, "warn"))
        .warn
    else if (std.ascii.eqlIgnoreCase(v, "err") or std.ascii.eqlIgnoreCase(v, "error"))
        .err
    else
        null;
    if (lvl) |l| min_level.store(@intFromEnum(l), .monotonic);
}

fn joinZ(buf: []u8, parts: []const []const u8) ?[:0]u8 {
    var w: usize = 0;
    for (parts) |p| {
        if (w + p.len + 1 > buf.len) return null;
        @memcpy(buf[w..][0..p.len], p);
        w += p.len;
    }
    buf[w] = 0;
    return buf[0..w :0];
}

/// `open_log_file_in(dir, mode)`: open (rotating) and install as the log sink.
/// Returns the fd, or null when the directory is unusable.
pub fn open(dir: []const u8, mode: []const u8) ?c.fd_t {
    const fd = openIn(dir, mode) orelse return null;
    const old = log_fd.swap(fd, .acq_rel);
    if (old >= 0) _ = c.close(old);
    return fd;
}

/// Close the sink (tests).
pub fn close() void {
    const fd = log_fd.swap(-1, .acq_rel);
    if (fd >= 0) _ = c.close(fd);
    path_len = 0;
}

pub fn openIn(dir: []const u8, mode: []const u8) ?c.fd_t {
    var dir_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = joinZ(&dir_z_buf, &.{dir}) orelse return null;
    mkdirAll(dir_z) catch return null;
    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = joinZ(&canon_buf, &.{ dir, "/zeron-", mode, ".log" }) orelse return null;
    const O: c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const preexisting = c.access(canonical, c.F_OK) == 0;
    // Probe the CURRENT inode for a live writer before touching it.
    const existing = c.open(canonical, O, @as(c.mode_t, 0o644));
    if (existing < 0) return null;
    if (c.flock(existing, c.LOCK.EX | c.LOCK.NB) != 0) {
        _ = c.close(existing);
        // A live process owns the canonical log — leave it alone.
        var pid_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{c.getpid()}) catch return null;
        var alt_buf: [std.fs.max_path_bytes]u8 = undefined;
        const alt = joinZ(&alt_buf, &.{ dir, "/zeron-", mode, ".", pid, ".log" }) orelse return null;
        const fd = c.open(alt, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        if (fd < 0) return null;
        remember(alt);
        return fd;
    }
    // No live writer: rotate, create fresh, and lock it as ours.
    _ = c.close(existing);
    if (preexisting) {
        var old_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old = joinZ(&old_buf, &.{ dir, "/zeron-", mode, ".log.old" }) orelse return null;
        _ = c.rename(canonical, old);
    }
    const fd = c.open(canonical, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return null;
    _ = c.flock(fd, c.LOCK.EX | c.LOCK.NB);
    remember(canonical);
    sweepStalePidLogs(dir_z, mode);
    return fd;
}

fn remember(p: []const u8) void {
    const n = @min(p.len, path_buf.len);
    @memcpy(path_buf[0..n], p[0..n]);
    path_len = n;
}

fn mkdirAll(p: [:0]u8) !void {
    if (c.mkdir(p, 0o755) == 0) return;
    if (c._errno().* == @intFromEnum(c.E.EXIST)) return;
    // Create parents, then retry.
    var i: usize = 1;
    while (i < p.len) : (i += 1) if (p[i] == '/') {
        p[i] = 0;
        _ = c.mkdir(p[0..i :0], 0o755);
        p[i] = '/';
    };
    if (c.mkdir(p, 0o755) != 0 and c._errno().* != @intFromEnum(c.E.EXIST)) return error.MkdirFailed;
}

/// Delete `zeron-{mode}.{pid}.log` overflow files older than a week.
fn sweepStalePidLogs(dir: [:0]const u8, mode: []const u8) void {
    const d = c.opendir(dir) orelse return;
    defer _ = c.closedir(d);
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "zeron-{s}.", .{mode}) catch return;
    var now_ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &now_ts);
    const now: i64 = @intCast(now_ts.sec);
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (name.len <= prefix.len + ".log".len) continue;
        if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".log")) continue;
        const middle = name[prefix.len .. name.len - ".log".len];
        if (middle.len == 0) continue;
        const all_digits = for (middle) |ch| {
            if (!std.ascii.isDigit(ch)) break false;
        } else true;
        if (!all_digits) continue;
        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = joinZ(&full_buf, &.{ dir, "/", name }) orelse continue;
        const mtime = mtimeOf(full) orelse continue;
        if (now - mtime > 7 * 24 * 60 * 60) _ = c.unlink(full);
    }
}

fn mtimeOf(p: [:0]const u8) ?i64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .MTIME = true }, &stx)) != .SUCCESS) return null;
        return stx.mtime.sec;
    }
    var st: c.Stat = undefined;
    if (c.stat(p, &st) != 0) return null;
    return @intCast(st.mtime().sec);
}

// ---------------------------------------------------------------------------------------
// std.log + panic integration (wired in main.zig `std_options` / `panic`)
// ---------------------------------------------------------------------------------------

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > min_level.load(.monotonic)) return;
    std.log.defaultLog(level, scope, format, args);
    const fd = log_fd.load(.acquire);
    if (fd < 0) return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeTimestamp(&w);
    const tag = switch (level) {
        .err => "ERROR",
        .warn => " WARN",
        .info => " INFO",
        .debug => "DEBUG",
    };
    w.print(" {s} {s}: ", .{ tag, if (scope == .default) "zeron" else @tagName(scope) }) catch {};
    w.print(format, args) catch {
        // Truncated: keep what fits and end the line.
        w.end = @min(w.end, buf.len - 4);
        @memcpy(buf[w.end..][0..3], "...");
        w.end += 3;
    };
    if (w.end < buf.len) {
        buf[w.end] = '\n';
        w.end += 1;
    }
    writeAll(fd, buf[0..w.end]);
}

/// RFC 3339 UTC with milliseconds, like tracing's default.
fn writeTimestamp(w: *std.Io.Writer) void {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(@max(ts.sec, 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,                  md.month.numeric(),          md.day_index + 1,
        ds.getHoursIntoDay(),      ds.getMinutesIntoHour(),     ds.getSecondsIntoMinute(),
        @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms,
    }) catch {};
}

fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// `panic::set_hook`: mirror the panic into the log, then std's handler (trace + abort).
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const fd = log_fd.load(.acquire);
    if (fd >= 0) {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        writeTimestamp(&w);
        w.print(" ERROR zeron: application panic: {s} (at 0x{x})\n", .{ msg, first_trace_addr orelse @returnAddress() }) catch {};
        writeAll(fd, w.buffered());
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "second launch never rotates a live process's log (zeron log_file_tests)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&tmp_buf, "/tmp/zeron-logtest-{d}", .{c.getpid()});
    var cleanup_buf: [300]u8 = undefined;
    defer {
        if (joinZ(&cleanup_buf, &.{ base, "/zeron-headed.log" })) |p| _ = c.unlink(p);
        if (joinZ(&cleanup_buf, &.{ base, "/zeron-headed.log.old" })) |p| _ = c.unlink(p);
        var pid_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{c.getpid()}) catch unreachable;
        if (joinZ(&cleanup_buf, &.{ base, "/zeron-headed.", pid, ".log" })) |p| _ = c.unlink(p);
        if (joinZ(&cleanup_buf, &.{base})) |p| _ = c.rmdir(p);
    }
    var probe: [300]u8 = undefined;

    const first = openIn(base, "headed").?;
    try testing.expect(c.access(joinZ(&probe, &.{ base, "/zeron-headed.log" }).?, c.F_OK) == 0);
    // Second launch while the first is alive: pid-suffixed overflow file instead.
    // (flock is per open file description, so a second open in this process conflicts.)
    const second = openIn(base, "headed").?;
    var pid_buf: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buf, "{d}", .{c.getpid()});
    try testing.expect(c.access(joinZ(&probe, &.{ base, "/zeron-headed.", pid, ".log" }).?, c.F_OK) == 0);
    try testing.expect(c.access(joinZ(&probe, &.{ base, "/zeron-headed.log.old" }).?, c.F_OK) != 0);
    _ = c.close(second);
    // After the owner exits, a fresh launch rotates normally.
    _ = c.close(first);
    const third = openIn(base, "headed").?;
    try testing.expect(c.access(joinZ(&probe, &.{ base, "/zeron-headed.log.old" }).?, c.F_OK) == 0);
    _ = c.close(third);
    path_len = 0;
}

test "ZERON_LOG levels" {
    defer min_level.store(@intFromEnum(std.log.Level.info), .monotonic);
    setLevelFromEnv("debug");
    try testing.expectEqual(@intFromEnum(std.log.Level.debug), min_level.load(.monotonic));
    setLevelFromEnv("WARN");
    try testing.expectEqual(@intFromEnum(std.log.Level.warn), min_level.load(.monotonic));
    setLevelFromEnv("bogus");
    try testing.expectEqual(@intFromEnum(std.log.Level.warn), min_level.load(.monotonic));
}
