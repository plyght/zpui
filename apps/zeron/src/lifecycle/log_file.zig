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
//! file before std's default panic handler prints the trace. `installCrashHandlers` does
//! the same for fatal signals (segfaults, aborts inside AppKit) and, on macOS, uncaught
//! Objective-C exceptions, with a symbolized backtrace.

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
// Native crashes: fatal signals and uncaught Objective-C exceptions
// ---------------------------------------------------------------------------------------
//
// A Zig panic reaches the log through `panicFn`; a segfault, an abort inside AppKit or an
// uncaught NSException did not, so the log ended at the last ordinary line. These write
// what they know (signal, fault address, image slide, return addresses with symbols via
// `backtrace_symbols_fd`; the exception's name, reason and call stack) into the log fd,
// then hand over to the previous handler (std's segfault trace) or the default action.

const posix = std.posix;
const fatal_signals = [_]posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT };
var previous_actions: [fatal_signals.len]posix.Sigaction = undefined;
var crash_handlers_installed = false;
var in_crash = std.atomic.Value(bool).init(false);

extern "c" fn backtrace(buffer: [*]?*anyopaque, size: c_int) c_int;
extern "c" fn backtrace_symbols_fd(buffer: [*]const ?*anyopaque, size: c_int, fd: c_int) void;
extern "c" fn _dyld_get_image_vmaddr_slide(image_index: u32) isize;

/// Install the fatal-signal (and, on macOS, uncaught-exception) loggers. Call once, after
/// `open`; std's own segfault handler stays chained behind ours.
pub fn installCrashHandlers() void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    if (crash_handlers_installed) return;
    crash_handlers_installed = true;
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = onFatalSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.ONSTACK,
    };
    for (fatal_signals, 0..) |sig, i| posix.sigaction(sig, &act, &previous_actions[i]);
    if (builtin.os.tag == .macos) NSSetUncaughtExceptionHandler(&onUncaughtException);
}

fn signalName(sig: posix.SIG) []const u8 {
    return switch (sig) {
        .SEGV => "SIGSEGV",
        .BUS => "SIGBUS",
        .ILL => "SIGILL",
        .FPE => "SIGFPE",
        .ABRT => "SIGABRT",
        else => "signal",
    };
}

fn faultAddress(info: *const posix.siginfo_t) usize {
    return switch (builtin.os.tag) {
        .macos => @intFromPtr(info.addr),
        .linux => @intFromPtr(info.fields.sigfault.addr),
        else => 0,
    };
}

/// Write "fatal signal" + a symbolized backtrace into the log (async-signal-safe calls only).
fn logBacktrace(fd: c.fd_t, header: []const u8) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeTimestamp(&w);
    w.writeAll(" ERROR zeron: ") catch {};
    w.writeAll(header) catch {};
    if (builtin.os.tag == .macos) w.print(" (image slide 0x{x})", .{@as(usize, @bitCast(_dyld_get_image_vmaddr_slide(0)))}) catch {};
    w.writeAll("\n") catch {};
    writeAll(fd, w.buffered());
    var frames: [64]?*anyopaque = undefined;
    const n = backtrace(&frames, frames.len);
    if (n > 0) backtrace_symbols_fd(&frames, n, fd);
}

fn onFatalSignal(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    const i = for (fatal_signals, 0..) |s, k| {
        if (s == sig) break k;
    } else return;
    const fd = log_fd.load(.acquire);
    if (fd >= 0 and !in_crash.swap(true, .acq_rel)) {
        var hb: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&hb, "fatal signal {s} (fault address 0x{x})", .{ signalName(sig), faultAddress(info) }) catch "fatal signal";
        logBacktrace(fd, header);
    }
    // Hand over: the previous handler (std's trace printer) or the default action.
    const prev = previous_actions[i];
    posix.sigaction(sig, &prev, null);
    if (prev.flags & posix.SA.SIGINFO != 0) {
        if (prev.handler.sigaction) |f| return @call(.auto, f, .{ sig, info, ctx });
    }
    // Default (or plain) action: a fault re-executes and hits it; an abort is re-raised.
    if (sig == .ABRT or sig == .FPE) _ = c.raise(sig);
}

// ---- macOS: uncaught Objective-C exceptions ----

extern "c" fn NSSetUncaughtExceptionHandler(handler: ?*const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn objc_msgSend() void;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;

fn msgId(obj: ?*anyopaque, sel: [*:0]const u8) ?*anyopaque {
    const o = obj orelse return null;
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    return f(o, sel_registerName(sel));
}

fn msgUtf8(obj: ?*anyopaque) []const u8 {
    const s = obj orelse return "(null)";
    const f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc_msgSend);
    const p = f(s, sel_registerName("UTF8String")) orelse return "(null)";
    return std.mem.sliceTo(p, 0);
}

fn onUncaughtException(exception: ?*anyopaque) callconv(.c) void {
    const fd = log_fd.load(.acquire);
    if (fd < 0) return;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeTimestamp(&w);
    w.print(" ERROR zeron: uncaught Objective-C exception {s}: {s}\n", .{
        msgUtf8(msgId(exception, "name")), msgUtf8(msgId(exception, "reason")),
    }) catch {};
    writeAll(fd, w.buffered());
    // `callStackSymbols`: one NSString per frame.
    const stack = msgId(exception, "callStackSymbols") orelse return;
    const count_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc_msgSend);
    const at_fn: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    const n = count_fn(stack, sel_registerName("count"));
    var k: usize = 0;
    while (k < n and k < 128) : (k += 1) {
        const line = msgUtf8(at_fn(stack, sel_registerName("objectAtIndex:"), k));
        writeAll(fd, line);
        writeAll(fd, "\n");
    }
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

test "a segfault and an abort are written to the log with a backtrace before the process dies" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    for ([_]posix.SIG{ .SEGV, .ABRT }) |which| {
        var dir_buf: [128]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/zeron-crashlog-{d}-{d}", .{ c.getpid(), @intFromEnum(which) });
        const pid = c.fork();
        try testing.expect(pid >= 0);
        if (pid == 0) {
            _ = open(dir, "crash") orelse c._exit(3);
            installCrashHandlers();
            if (which == .SEGV) {
                const p: *volatile u8 = @ptrFromInt(8);
                p.* = 1;
            }
            c.abort();
        }
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        try testing.expect(c.W.IFSIGNALED(@bitCast(status)));
        var file_buf: [256]u8 = undefined;
        const file = joinZ(&file_buf, &.{ dir, "/zeron-crash.log" }).?;
        const fd = c.open(file, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
        try testing.expect(fd >= 0);
        var text: [16384]u8 = undefined;
        const n = c.read(fd, &text, text.len);
        _ = c.close(fd);
        _ = c.unlink(file);
        _ = c.rmdir(joinZ(&file_buf, &.{dir}).?);
        try testing.expect(n > 0);
        const got = text[0..@intCast(n)];
        try testing.expect(std.mem.indexOf(u8, got, if (which == .SEGV) "fatal signal SIGSEGV" else "fatal signal SIGABRT") != null);
        try testing.expect(std.mem.count(u8, got, "\n") >= 3); // header + backtrace frames
    }
}
