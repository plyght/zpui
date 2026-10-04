//! A minimal POSIX pseudo-terminal runner (libc `forkpty`), used by tests
//! and `examples/term_dump.zig` to run real programs (ls, vim, htop-style
//! cursor work) and feed their output into the emulator. The real app gets
//! its PTY from the engine over RPC; this is a local stand-in.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Emulator = @import("Emulator.zig");

const c = std.c;
const fd_t = c.fd_t;

extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const std.posix.winsize) c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// Extra environment for the child (TERM defaults to xterm-256color).
    env: []const [2][:0]const u8 = &.{},
    cwd: ?[:0]const u8 = null,
};

pub const Pty = struct {
    master: fd_t,
    pid: c.pid_t,
    exit_status: ?u32 = null,

    /// Fork `argv[0]` (PATH lookup) on a new PTY of the given size.
    pub fn spawn(argv: []const [:0]const u8, opts: Options) !Pty {
        if (argv.len == 0 or argv.len > 63) return error.InvalidArgv;
        var argv_buf: [64:null]?[*:0]const u8 = @splat(null);
        for (argv, 0..) |a, i| argv_buf[i] = a.ptr;

        const ws: std.posix.winsize = .{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
        var master: c_int = -1;
        const pid = forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            // Child: no allocation, just environment + exec.
            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("COLORTERM", "truecolor", 1);
            _ = setenv("LANG", "C.UTF-8", 0);
            for (opts.env) |kv| _ = setenv(kv[0].ptr, kv[1].ptr, 1);
            if (opts.cwd) |dir| _ = c.chdir(dir.ptr);
            _ = execvp(argv_buf[0].?, &argv_buf);
            c._exit(127);
        }
        return .{ .master = master, .pid = pid };
    }

    pub fn write(self: *Pty, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(self.master, rest.ptr, rest.len);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            rest = rest[@intCast(n)..];
        }
    }

    /// Read whatever is available within `timeout_ms`. Returns 0 on
    /// timeout and null at EOF (the child side closed).
    pub fn read(self: *Pty, buf: []u8, timeout_ms: i32) !?usize {
        var fds = [1]c.pollfd{.{ .fd = self.master, .events = c.POLL.IN, .revents = 0 }};
        const pr = c.poll(&fds, 1, timeout_ms);
        if (pr < 0) {
            if (std.posix.errno(pr) == .INTR) return 0;
            return error.PollFailed;
        }
        if (pr == 0) return 0;
        const n = c.read(self.master, buf.ptr, buf.len);
        if (n < 0) {
            return switch (std.posix.errno(n)) {
                .INTR, .AGAIN => 0,
                .IO => null, // Linux: slave closed
                else => error.ReadFailed,
            };
        }
        if (n == 0) return null;
        return @intCast(n);
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        const ws: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (comptime builtin.os.tag.isDarwin()) {
            // std.c has no Darwin TIOCSWINSZ, and its `ioctl` takes the request as c_int
            // while Darwin's is `unsigned long` (the value has the top bit set).
            _ = darwin_ioctl(self.master, darwin_TIOCSWINSZ, &ws);
        } else {
            _ = c.ioctl(self.master, c.T.IOCSWINSZ, @intFromPtr(&ws));
        }
    }

    /// `_IOW('t', 103, struct winsize)` (<sys/ttycom.h>).
    const darwin_TIOCSWINSZ: c_ulong = 0x80000000 | (@as(c_ulong, @sizeOf(std.posix.winsize) & 0x1fff) << 16) | ('t' << 8) | 103;
    const darwin_ioctl = @extern(*const fn (c_int, c_ulong, ...) callconv(.c) c_int, .{ .name = "ioctl" });

    /// Current size of the terminal (rows, cols), for tests.
    pub fn size(self: *Pty) ?struct { cols: u16, rows: u16 } {
        var ws: std.posix.winsize = undefined;
        const req = if (comptime builtin.os.tag.isDarwin()) darwin_TIOCGWINSZ else c.T.IOCGWINSZ;
        const rc = if (comptime builtin.os.tag.isDarwin()) darwin_ioctl(self.master, req, &ws) else c.ioctl(self.master, req, @intFromPtr(&ws));
        if (rc < 0) return null;
        return .{ .cols = ws.col, .rows = ws.row };
    }

    /// `_IOR('t', 104, struct winsize)`.
    const darwin_TIOCGWINSZ: c_ulong = 0x40000000 | (@as(c_ulong, @sizeOf(std.posix.winsize) & 0x1fff) << 16) | ('t' << 8) | 104;

    /// Reap the child if it has exited (non-blocking unless `block`).
    pub fn poll(self: *Pty, block: bool) ?u32 {
        if (self.exit_status) |s| return s;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, if (block) 0 else c.W.NOHANG);
        if (r == self.pid) self.exit_status = @bitCast(status);
        return self.exit_status;
    }

    pub fn exitCode(self: *Pty) ?u8 {
        const s = self.exit_status orelse return null;
        return c.W.EXITSTATUS(s);
    }

    pub fn deinit(self: *Pty) void {
        if (self.poll(false) == null) {
            _ = c.kill(self.pid, .TERM);
            _ = self.poll(true);
        }
        _ = c.close(self.master);
    }
};

comptime {
    // Keep every platform's ioctl path compiled (the macOS app build only links `resize`).
    _ = &Pty.size;
}

/// A scripted interaction step: wait `delay_ms` (while pumping output),
/// then write `input` to the program.
pub const Step = struct {
    delay_ms: u32 = 0,
    input: []const u8 = "",
};

pub const RunOptions = struct {
    pty: Options = .{},
    steps: []const Step = &.{},
    /// Give up after this long (the child is then killed).
    timeout_ms: u32 = 10_000,
    /// Optionally record every byte the program printed.
    capture: ?*std.ArrayList(u8) = null,
};

/// Run a program under a PTY sized to the emulator, feeding its output into
/// `emu` live and answering its terminal queries (DA/DSR/...), until it
/// exits and its output is drained. Returns the exit code.
pub fn run(gpa: Allocator, emu: *Emulator, argv: []const [:0]const u8, opts: RunOptions) !u8 {
    var po = opts.pty;
    po.cols = emu.cols();
    po.rows = emu.rows();
    var p = try Pty.spawn(argv, po);
    defer p.deinit();

    var buf: [16 * 1024]u8 = undefined;
    var elapsed: u32 = 0;
    var step: usize = 0;
    var step_wait: u32 = 0;
    const tick: i32 = 10;
    while (true) {
        if (elapsed >= opts.timeout_ms) return error.Timeout;
        // Next scripted input once its delay has passed.
        if (step < opts.steps.len and step_wait >= opts.steps[step].delay_ms) {
            if (opts.steps[step].input.len > 0) p.write(opts.steps[step].input) catch {};
            step += 1;
            step_wait = 0;
        }
        const got = try p.read(&buf, tick);
        if (got) |n| {
            if (n == 0) {
                elapsed += @intCast(tick);
                step_wait += @intCast(tick);
                if (p.poll(false) != null) {
                    // Exited and nothing left within one tick (pending
                    // scripted input is moot).
                    break;
                }
                continue;
            }
            if (opts.capture) |cap| try cap.appendSlice(gpa, buf[0..n]);
            const resp = emu.feed(buf[0..n]);
            if (resp.len > 0) p.write(resp) catch {};
        } else break; // EOF
    }
    _ = p.poll(true);
    return p.exitCode() orelse 255;
}

test "resize sets the PTY window size" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var p = try Pty.spawn(&.{ "/bin/sh", "-c", "sleep 1" }, .{ .cols = 80, .rows = 24 });
    defer p.deinit();
    const s0 = p.size().?;
    try std.testing.expectEqual(@as(u16, 80), s0.cols);
    try std.testing.expectEqual(@as(u16, 24), s0.rows);
    p.resize(132, 40);
    const s1 = p.size().?;
    try std.testing.expectEqual(@as(u16, 132), s1.cols);
    try std.testing.expectEqual(@as(u16, 40), s1.rows);
}
