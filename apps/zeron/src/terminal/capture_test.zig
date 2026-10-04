//! Real-world output tests: recorded captures (testdata/*.bin, made by
//! testdata/capture.py under an 80x24 PTY), vttest-style sequences, and
//! live programs run under a PTY (`pty.zig`).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const gpa = testing.allocator;
const Emulator = @import("Emulator.zig");
const snapshot = @import("snapshot.zig");
const pty = @import("pty.zig");

fn emu(cols: u16, rows: u16) !*Emulator {
    return Emulator.create(gpa, .{ .cols = cols, .rows = rows, .io = testing.io });
}

fn expectRow(e: *Emulator, row: usize, expected: []const u8) !void {
    const got = try e.rowText(gpa, row);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectRowStartsWith(e: *Emulator, row: usize, prefix: []const u8) !void {
    const got = try e.rowText(gpa, row);
    defer gpa.free(got);
    if (!std.mem.startsWith(u8, got, prefix)) {
        std.debug.print("row {d}: expected prefix '{s}', got '{s}'\n", .{ row, prefix, got });
        return error.TestExpectedEqual;
    }
}

// ---- recorded captures ---------------------------------------------------

test "capture: ls --color" {
    const e = try emu(80, 24);
    defer e.destroy();
    _ = e.feed(@embedFile("testdata/ls_color_0.bin"));
    try expectRow(e, 0, "Cargo.toml  README.md  build  docs  link.md  notes.txt  run.sh  src");
    const s = try e.snapshot();
    const l = s.lines[0].cells;
    // "build" is bold blue (01;34), "link.md" bold cyan, "run.sh" bold green.
    try testing.expect(l[23].attrs.bold);
    try testing.expect(l[23].fg.eql(.{ .indexed = 4 }));
    try testing.expect(l[36].fg.eql(.{ .indexed = 6 }));
    try testing.expect(l[56].fg.eql(.{ .indexed = 2 }));
    try testing.expect(l[0].fg.eql(.default));
    try testing.expectEqual(Emulator.ViewportPoint{ .row = 1, .col = 0 }, e.cursor().?);
}

test "capture: vim alt-screen session" {
    const e = try emu(80, 24);
    defer e.destroy();
    _ = e.feed("$ vim demo.txt\r\n");

    // Startup: alt screen, empty buffer with ~ filler, file message.
    _ = e.feed(@embedFile("testdata/vim_0.bin"));
    try testing.expect(e.altScreen());
    try testing.expect(e.appCursorMode());
    try testing.expect(e.bracketedPasteMode());
    try expectRow(e, 1, "~");
    try expectRow(e, 22, "~");
    try expectRowStartsWith(e, 23, "\"demo.txt\" [New]");
    const filler = (try e.snapshot()).lines[1].cells[0];
    try testing.expect(filler.fg.eql(.{ .indexed = 12 })); // \e[94m

    // Insert mode typing.
    _ = e.feed(@embedFile("testdata/vim_1.bin"));
    try expectRow(e, 0, "hello from vim");
    try expectRow(e, 1, "        indented line");
    try expectRow(e, 23, "-- INSERT --");

    // :set number -> colored gutter (38;5;130).
    _ = e.feed(@embedFile("testdata/vim_2.bin"));
    try expectRow(e, 0, "  1 hello from vim");
    try expectRow(e, 1, "  2         indented line");
    try testing.expect((try e.snapshot()).lines[0].cells[2].fg.eql(.{ .indexed = 130 }));

    // :wq -> leaves the alt screen, primary content is back.
    _ = e.feed(@embedFile("testdata/vim_3.bin"));
    try testing.expect(!e.altScreen());
    try testing.expect(!e.appCursorMode());
    try testing.expect(!e.bracketedPasteMode());
    try expectRow(e, 0, "$ vim demo.txt");
    try testing.expect(e.cursor() != null);
}

test "capture: top (cursor addressing, reverse video, charset resets)" {
    const e = try emu(80, 24);
    defer e.destroy();
    _ = e.feed(@embedFile("testdata/top_0.bin"));
    try expectRowStartsWith(e, 0, "top - ");
    try expectRowStartsWith(e, 1, "Tasks:");
    try expectRowStartsWith(e, 6, "  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND");
    const s = try e.snapshot();
    try testing.expect(s.lines[6].cells[2].attrs.inverse);
    try testing.expect(s.lines[1].cells[8].attrs.bold); // task count
    try testing.expect(e.cursor() == null); // ?25l while running
    _ = e.feed(@embedFile("testdata/top_1.bin"));
    try testing.expect(e.cursor() != null);
    try testing.expect(!e.appCursorMode());
}

// ---- vttest-style sequences --------------------------------------------

test "vttest: DECALN screen alignment" {
    const e = try emu(10, 3);
    defer e.destroy();
    _ = e.feed("\x1b#8");
    for (0..3) |r| try expectRow(e, r, "EEEEEEEEEE");
}

test "vttest: scroll region with index/reverse index" {
    const e = try emu(10, 5);
    defer e.destroy();
    _ = e.feed("1\r\n2\r\n3\r\n4\r\n5");
    _ = e.feed("\x1b[2;4r"); // region rows 2..4
    _ = e.feed("\x1b[4;1H\n"); // LF at bottom margin scrolls the region
    try expectRow(e, 0, "1");
    try expectRow(e, 1, "3");
    try expectRow(e, 2, "4");
    try expectRow(e, 3, "");
    try expectRow(e, 4, "5");
    _ = e.feed("\x1b[2;1H\x1bM"); // RI at top margin scrolls down
    try expectRow(e, 1, "");
    try expectRow(e, 2, "3");
    try expectRow(e, 4, "5");
}

test "vttest: insert/delete lines and characters" {
    const e = try emu(10, 4);
    defer e.destroy();
    _ = e.feed("aaaa\r\nbbbb\r\ncccc\r\ndddd");
    _ = e.feed("\x1b[2;1H\x1b[L");
    try expectRow(e, 1, "");
    try expectRow(e, 2, "bbbb");
    try expectRow(e, 3, "cccc");
    _ = e.feed("\x1b[M");
    try expectRow(e, 1, "bbbb");
    _ = e.feed("\x1b[1;2H\x1b[2P");
    try expectRow(e, 0, "aa");
    _ = e.feed("\x1b[1;1H\x1b[3@");
    try expectRow(e, 0, "   aa");
    _ = e.feed("\x1b[1;1H\x1b[2X");
    try expectRow(e, 0, "   aa");
}

test "vttest: tab stops" {
    const e = try emu(30, 2);
    defer e.destroy();
    _ = e.feed("a\tb\tc");
    try expectRow(e, 0, "a       b       c");
    _ = e.feed("\r\n\x1b[3g\x1b[1;5H\x1bH\r\n\tX"); // clear all, set at col 5
    try expectRow(e, 1, "    X");
}

test "vttest: DEC special graphics charset" {
    const e = try emu(10, 2);
    defer e.destroy();
    _ = e.feed("\x1b(0lqqk\x1b(Bx");
    try expectRow(e, 0, "┌──┐x");
}

test "vttest: save/restore cursor and attributes (DECSC/DECRC)" {
    const e = try emu(20, 3);
    defer e.destroy();
    _ = e.feed("\x1b[2;5H\x1b[1;31m\x1b7\x1b[0m\x1b[H\x1b8X");
    const c = (try e.snapshot()).lines[1].cells[4];
    try testing.expectEqual(@as(u21, 'X'), c.codepoint);
    try testing.expect(c.attrs.bold);
    try testing.expect(c.fg.eql(.{ .indexed = 1 }));
}

test "vttest: DECRQM mode report" {
    const e = try emu(20, 3);
    defer e.destroy();
    _ = e.feed("\x1b[?2004h");
    try testing.expectEqualStrings("\x1b[?2004;1$y", e.feed("\x1b[?2004$p"));
    try testing.expectEqualStrings("\x1b[?1049;2$y", e.feed("\x1b[?1049$p"));
}

test "vttest: synchronized output mode" {
    const e = try emu(20, 3);
    defer e.destroy();
    _ = e.feed("\x1b[?2026h");
    try testing.expect(e.renderHeld());
    _ = e.feed("\x1b[?2026l");
    try testing.expect(!e.renderHeld());
}

test "full reset (RIS) clears title and screen" {
    const e = try emu(20, 3);
    defer e.destroy();
    _ = e.feed("\x1b]0;t\x07hello\x1bc");
    try testing.expect(e.title() == null);
    try expectRow(e, 0, "");
}

// ---- live programs under a PTY -----------------------------------------

test "pty: printf with cursor movement (htop-ish redraw)" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const e = try emu(40, 6);
    defer e.destroy();
    const script =
        \\printf '\033[2J\033[H'
        \\printf 'CPU [\033[32m||||\033[0m      ] 40%%\n'
        \\printf 'MEM [\033[33m||||||\033[0m    ] 60%%\n'
        \\printf '\033[1;22HLoad: 1.0'
        \\printf '\033[2;22HLoad: 2.0'
        \\printf '\033[1;22HLoad: 3.5'
        \\printf '\033[5;1H\033[7m F10 Quit \033[0m'
    ;
    const code = try pty.run(gpa, e, &.{ "sh", "-c", script }, .{});
    try testing.expectEqual(@as(u8, 0), code);
    try expectRow(e, 0, "CPU [||||      ] 40% Load: 3.5");
    try expectRow(e, 1, "MEM [||||||    ] 60% Load: 2.0");
    try expectRow(e, 4, " F10 Quit");
    const s = try e.snapshot();
    try testing.expect(s.lines[0].cells[5].fg.eql(.{ .indexed = 2 }));
    try testing.expect(s.lines[4].cells[1].attrs.inverse);
}

test "pty: child sees the emulator size and TERM" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const e = try emu(57, 13);
    defer e.destroy();
    _ = try pty.run(gpa, e, &.{ "sh", "-c", "printf '%s %s' \"$(stty size)\" \"$TERM\"" }, .{});
    try expectRow(e, 0, "13 57 xterm-256color");
}

test "pty: exit code propagates" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const e = try emu(20, 3);
    defer e.destroy();
    try testing.expectEqual(@as(u8, 3), try pty.run(gpa, e, &.{ "sh", "-c", "exit 3" }, .{}));
}

test "pty: interactive input (cat echoes typed keys)" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const e = try emu(30, 4);
    defer e.destroy();
    _ = try pty.run(gpa, e, &.{ "sh", "-c", "read line; echo \"got:$line\"" }, .{
        .steps = &.{.{ .delay_ms = 100, .input = "zig\r" }},
    });
    try expectRow(e, 0, "zig");
    try expectRow(e, 1, "got:zig");
}
