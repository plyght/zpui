//! Emulator tests: zeron `emulator.rs` test suite ported 1:1, plus coverage
//! for the extra surface (modes, SGR attrs, graphemes, hyperlinks, cursor
//! styles, damage, reflow, input encoders).
const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Emulator = @import("Emulator.zig");
const snapshot = @import("snapshot.zig");
const input = @import("input.zig");
const CellColor = snapshot.CellColor;

fn emu(cols: u16, rows: u16) !*Emulator {
    return Emulator.create(gpa, .{ .cols = cols, .rows = rows, .io = testing.io });
}

fn expectRow(e: *Emulator, row: usize, expected: []const u8) !void {
    const got = try e.rowText(gpa, row);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectCursor(e: *Emulator, expected: ?Emulator.ViewportPoint) !void {
    try testing.expectEqual(expected, e.cursor());
}

fn expectSelection(e: *Emulator, expected: ?[]const u8) !void {
    const got = try e.selectionText(gpa);
    defer if (got) |g| gpa.free(g);
    if (expected) |exp| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(exp, got.?);
    } else try testing.expect(got == null);
}

fn line(e: *Emulator, row: usize) ![]const snapshot.Cell {
    const s = try e.snapshot();
    return s.lines[row].cells;
}

fn feed(e: *Emulator, bytes: []const u8) void {
    _ = e.feed(bytes);
}

// ---- emulator.rs tests -------------------------------------------------

test "plain text lands on row zero" {
    const e = try emu(20, 5);
    defer e.destroy();
    feed(e, "hello");
    try expectRow(e, 0, "hello");
    try expectCursor(e, .{ .row = 0, .col = 5 });
}

test "crlf moves lines and cr returns to column zero" {
    const e = try emu(20, 5);
    defer e.destroy();
    feed(e, "one\r\ntwo\r\nthree");
    try expectRow(e, 0, "one");
    try expectRow(e, 1, "two");
    try expectRow(e, 2, "three");
    feed(e, "\rXX");
    try expectRow(e, 2, "XXree");
}

test "long line wraps at the grid width" {
    const e = try emu(10, 4);
    defer e.destroy();
    feed(e, "abcdefghijKLM");
    try expectRow(e, 0, "abcdefghij");
    try expectRow(e, 1, "KLM");
    try testing.expect((try e.snapshot()).lines[0].wrapped);
}

test "sgr colors and attributes" {
    const e = try emu(40, 4);
    defer e.destroy();
    feed(e, "\x1b[31mred\x1b[0m plain \x1b[1;44mboldbg\x1b[0m");
    const l = try line(e, 0);
    try testing.expect(l[0].fg.eql(.{ .indexed = 1 }));
    try testing.expect(l[0].bg.eql(.default));
    try testing.expect(l[4].fg.eql(.default));
    try testing.expect(l[10].attrs.bold);
    try testing.expect(l[10].bg.eql(.{ .indexed = 4 }));
}

test "bright 256 and truecolor sgr" {
    const e = try emu(40, 2);
    defer e.destroy();
    feed(e, "\x1b[95mA\x1b[38;5;196mB\x1b[38;2;10;20;30mC");
    const l = try line(e, 0);
    try testing.expect(l[0].fg.eql(.{ .indexed = 13 }));
    try testing.expect(l[1].fg.eql(.{ .indexed = 196 }));
    try testing.expect(l[2].fg.eql(.{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }));
}

test "inverse and hidden resolve in display colors" {
    const e = try emu(10, 2);
    defer e.destroy();
    feed(e, "\x1b[7mI\x1b[0m\x1b[8mH");
    const l = try line(e, 0);
    try testing.expect(l[0].attrs.inverse);
    const inv = l[0].displayColors();
    try testing.expectEqual(snapshot.Slot.bg, inv.fg_slot);
    try testing.expectEqual(snapshot.Slot.fg, inv.bg_slot);
    try testing.expect(l[1].attrs.invisible);
    const hid = l[1].displayColors();
    try testing.expect(hid.fg.eql(hid.bg));
    try testing.expectEqual(hid.fg_slot, hid.bg_slot);
}

test "cursor addressing and relative moves" {
    const e = try emu(20, 6);
    defer e.destroy();
    feed(e, "\x1b[3;5Hx");
    try testing.expectEqual(@as(u21, 'x'), (try line(e, 2))[4].codepoint);
    try expectCursor(e, .{ .row = 2, .col = 5 });
    feed(e, "\x1b[2D");
    try expectCursor(e, .{ .row = 2, .col = 3 });
    feed(e, "\x1b[A");
    try expectCursor(e, .{ .row = 1, .col = 3 });
}

test "clear screen and home" {
    const e = try emu(20, 4);
    defer e.destroy();
    feed(e, "aaa\r\nbbb\r\nccc");
    feed(e, "\x1b[2J\x1b[H");
    for (0..4) |r| try expectRow(e, r, "");
    try expectCursor(e, .{ .row = 0, .col = 0 });
    feed(e, "fresh");
    try expectRow(e, 0, "fresh");
}

test "erase line variants" {
    const e = try emu(20, 2);
    defer e.destroy();
    feed(e, "abcdef\x1b[3D\x1b[K");
    try expectRow(e, 0, "abc");
    feed(e, "\r\nxyz123\x1b[3D\x1b[1K");
    try expectRow(e, 1, "    23");
    feed(e, "\x1b[2K");
    try expectRow(e, 1, "");
}

test "scrollback history and scrolling" {
    const e = try emu(10, 3);
    defer e.destroy();
    var buf: [16]u8 = undefined;
    for (1..9) |i| feed(e, try std.fmt.bufPrint(&buf, "line{d}\r\n", .{i}));
    try expectRow(e, 0, "line7");
    try testing.expectEqual(@as(usize, 6), e.historyLines());
    try testing.expectEqual(@as(usize, 0), e.displayOffset());
    e.scroll(2);
    try testing.expectEqual(@as(usize, 2), e.displayOffset());
    try expectRow(e, 0, "line5");
    try expectCursor(e, null);
    e.scroll(100);
    try testing.expectEqual(@as(usize, 6), e.displayOffset());
    try expectRow(e, 0, "line1");
    e.scrollToOffset(3);
    try testing.expectEqual(@as(usize, 3), e.displayOffset());
    try expectRow(e, 0, "line4");
    e.scrollToOffset(std.math.maxInt(usize));
    try testing.expectEqual(@as(usize, 6), e.displayOffset());
    e.scrollToBottom();
    try testing.expectEqual(@as(usize, 0), e.displayOffset());
    try expectRow(e, 0, "line7");
}

test "alt screen restores primary content" {
    const e = try emu(20, 4);
    defer e.destroy();
    feed(e, "primary");
    feed(e, "\x1b[?1049h\x1b[H");
    try testing.expect(e.altScreen());
    feed(e, "alt-content");
    try expectRow(e, 0, "alt-content");
    feed(e, "\x1b[?1049l");
    try testing.expect(!e.altScreen());
    try expectRow(e, 0, "primary");
}

test "dsr cursor report produces pty response" {
    const e = try emu(20, 4);
    defer e.destroy();
    feed(e, "\x1b[2;3H");
    try testing.expectEqualStrings("\x1b[2;3R", e.feed("\x1b[6n"));
}

test "device attributes are answered" {
    const e = try emu(20, 4);
    defer e.destroy();
    const r = e.feed("\x1b[c");
    try testing.expect(std.mem.startsWith(u8, r, "\x1b[?"));
    try testing.expect(std.mem.endsWith(u8, r, "c"));
}

test "osc title and bell" {
    const e = try emu(20, 2);
    defer e.destroy();
    try testing.expectEqual(@as(?[]const u8, null), e.title());
    feed(e, "\x1b]0;my title\x07");
    try testing.expectEqualStrings("my title", e.title().?);
    feed(e, "\x1b]2;other\x1b\\");
    try testing.expectEqualStrings("other", e.title().?);
    try testing.expect(!e.takeBell());
    feed(e, "\x07");
    try testing.expect(e.takeBell());
    try testing.expect(!e.takeBell());
}

test "app cursor and bracketed paste modes toggle" {
    const e = try emu(10, 2);
    defer e.destroy();
    try testing.expect(!e.appCursorMode());
    feed(e, "\x1b[?1h");
    try testing.expect(e.appCursorMode());
    feed(e, "\x1b[?1l");
    try testing.expect(!e.appCursorMode());
    feed(e, "\x1b[?2004h");
    try testing.expect(e.bracketedPasteMode());
    feed(e, "\x1b=");
    try testing.expect(e.appKeypadMode());
    feed(e, "\x1b>");
    try testing.expect(!e.appKeypadMode());
}

test "hidden cursor mode" {
    const e = try emu(10, 2);
    defer e.destroy();
    feed(e, "\x1b[?25l");
    try expectCursor(e, null);
    try testing.expect((try e.snapshot()).cursor == null);
    feed(e, "\x1b[?25h");
    try testing.expect(e.cursor() != null);
}

test "resize preserves content and reflows cursor" {
    const e = try emu(20, 5);
    defer e.destroy();
    feed(e, "keepme\r\nsecond");
    try e.resize(30, 3);
    try testing.expectEqual(@as(u16, 30), e.cols());
    try testing.expectEqual(@as(u16, 3), e.rows());
    try expectRow(e, 0, "keepme");
    try expectRow(e, 1, "second");
}

test "wide chars occupy two cells with spacer" {
    const e = try emu(10, 2);
    defer e.destroy();
    feed(e, "宽w");
    const l = try line(e, 0);
    try testing.expectEqual(snapshot.Wide.wide, l[0].wide);
    try testing.expectEqual(@as(u21, '宽'), l[0].codepoint);
    try testing.expectEqual(snapshot.Wide.spacer_tail, l[1].wide);
    try testing.expectEqual(@as(u21, 'w'), l[2].codepoint);
    try expectRow(e, 0, "宽w");
    try expectCursor(e, .{ .row = 0, .col = 3 });
}

test "simple selection yields its text and marks its cells" {
    const e = try emu(20, 3);
    defer e.destroy();
    feed(e, "hello world");
    try testing.expect(!e.hasSelection());
    try expectSelection(e, null);
    try e.startSelection(.simple, .{ .row = 0, .col = 0 }, .left);
    try e.updateSelection(.{ .row = 0, .col = 4 }, .right);
    try testing.expect(e.hasSelection());
    try expectSelection(e, "hello");
    const l = try line(e, 0);
    for (l[0..5]) |c| try testing.expect(c.selected);
    try testing.expect(!l[5].selected);
    e.clearSelection();
    try testing.expect(!e.hasSelection());
    for (try line(e, 0)) |c| try testing.expect(!c.selected);
}

test "semantic selection expands to the word" {
    const e = try emu(30, 2);
    defer e.destroy();
    feed(e, "alpha beta gamma");
    try e.startSelection(.semantic, .{ .row = 0, .col = 7 }, .left);
    try expectSelection(e, "beta");
    // Dragging onto another word extends by whole words.
    try e.updateSelection(.{ .row = 0, .col = 13 }, .left);
    try expectSelection(e, "beta gamma");
}

test "line selection takes the whole row" {
    const e = try emu(30, 3);
    defer e.destroy();
    feed(e, "first row\r\nsecond row");
    try e.startSelection(.lines, .{ .row = 1, .col = 3 }, .left);
    try expectSelection(e, "second row\n");
}

test "block selection is rectangular" {
    const e = try emu(10, 3);
    defer e.destroy();
    feed(e, "abcdef\r\nghijkl\r\nmnopqr");
    try e.startSelection(.block, .{ .row = 0, .col = 1 }, .left);
    try e.updateSelection(.{ .row = 2, .col = 3 }, .right);
    try expectSelection(e, "bcd\nhij\nnop");
}

test "selection spans rows with a newline" {
    const e = try emu(10, 3);
    defer e.destroy();
    feed(e, "ab\r\ncd");
    try e.startSelection(.simple, .{ .row = 0, .col = 0 }, .left);
    try e.updateSelection(.{ .row = 1, .col = 1 }, .right);
    try expectSelection(e, "ab\ncd");
}

test "selection follows its text when output scrolls" {
    const e = try emu(10, 3);
    defer e.destroy();
    feed(e, "target\r\n");
    try e.startSelection(.simple, .{ .row = 0, .col = 0 }, .left);
    try e.updateSelection(.{ .row = 0, .col = 5 }, .right);
    try expectSelection(e, "target");
    feed(e, "a\r\nb\r\nc\r\n");
    try expectSelection(e, "target");
}

test "a click without a drag selects nothing" {
    const e = try emu(20, 2);
    defer e.destroy();
    feed(e, "hello");
    try e.startSelection(.simple, .{ .row = 0, .col = 2 }, .left);
    try expectSelection(e, null);
    try testing.expect(!e.hasSelection());
}

test "utf8 split across feeds reassembles" {
    const e = try emu(10, 2);
    defer e.destroy();
    const bytes = "é";
    feed(e, bytes[0..1]);
    feed(e, bytes[1..]);
    try expectRow(e, 0, "é");
}

// ---- beyond emulator.rs ------------------------------------------------

test "grapheme clusters stay in one cell" {
    const e = try emu(10, 2);
    defer e.destroy();
    // e + combining acute, then a ZWJ family emoji (wide).
    feed(e, "e\u{301}\u{1F469}\u{200D}\u{1F467}x");
    const l = try line(e, 0);
    try testing.expectEqual(@as(u21, 'e'), l[0].codepoint);
    try testing.expectEqualSlices(u21, &.{0x301}, l[0].grapheme);
    try testing.expectEqual(@as(u21, 0x1F469), l[1].codepoint);
    try testing.expectEqual(snapshot.Wide.wide, l[1].wide);
    try testing.expectEqualSlices(u21, &.{ 0x200D, 0x1F467 }, l[1].grapheme);
    try testing.expectEqual(@as(u21, 'x'), l[3].codepoint);
}

test "sgr underline styles, faint, italic, strikethrough, underline color" {
    const e = try emu(20, 2);
    defer e.destroy();
    feed(e, "\x1b[2;3;9mA\x1b[0m\x1b[4:3;58;5;196mB\x1b[0m\x1b[21mC");
    const l = try line(e, 0);
    try testing.expect(l[0].attrs.faint and l[0].attrs.italic and l[0].attrs.strikethrough);
    try testing.expectEqual(snapshot.Underline.curly, l[1].underline);
    try testing.expect(l[1].underline_color.eql(.{ .indexed = 196 }));
    try testing.expectEqual(snapshot.Underline.double, l[2].underline);
}

test "erase with background color paints bg-only cells" {
    const e = try emu(10, 2);
    defer e.destroy();
    feed(e, "\x1b[44m\x1b[2K\x1b[0m");
    const l = try line(e, 0);
    try testing.expect(l[5].bg.eql(.{ .indexed = 4 }));
    try testing.expect(l[5].isEmpty());
}

test "osc 8 hyperlinks" {
    const e = try emu(30, 2);
    defer e.destroy();
    feed(e, "see \x1b]8;;https://zeron.sh\x1b\\docs\x1b]8;;\x1b\\ now");
    const l = try line(e, 0);
    try testing.expect(!l[3].hyperlink);
    try testing.expect(l[4].hyperlink and l[7].hyperlink);
    try testing.expect(!l[8].hyperlink);
    try testing.expectEqualStrings("https://zeron.sh", e.hyperlinkAt(.{ .row = 0, .col = 5 }).?);
    try testing.expect(e.hyperlinkAt(.{ .row = 0, .col = 9 }) == null);
}

test "osc 52 clipboard write reaches the callback" {
    const e = try emu(10, 2);
    defer e.destroy();
    const S = struct {
        var got: [32]u8 = undefined;
        var len: usize = 0;
        fn cb(_: ?*anyopaque, loc: Emulator.ClipboardLocation, text: []const u8) void {
            std.debug.assert(loc == .standard);
            @memcpy(got[0..text.len], text);
            len = text.len;
        }
    };
    e.callbacks.clipboard_write = &S.cb;
    feed(e, "\x1b]52;c;aGVsbG8=\x07");
    try testing.expectEqualStrings("hello", S.got[0..S.len]);
}

test "title callback fires" {
    const e = try emu(10, 2);
    defer e.destroy();
    const S = struct {
        var count: usize = 0;
        fn cb(_: ?*anyopaque, t: ?[]const u8) void {
            if (t) |s| std.debug.assert(std.mem.eql(u8, s, "vim")) else {}
            count += 1;
        }
    };
    e.callbacks.title = &S.cb;
    feed(e, "\x1b]2;vim\x07");
    try testing.expectEqual(@as(usize, 1), S.count);
}

test "cursor styles (DECSCUSR)" {
    const e = try emu(10, 2);
    defer e.destroy();
    try testing.expectEqual(snapshot.CursorStyle.block, (try e.snapshot()).cursor.?.style);
    feed(e, "\x1b[6 q");
    var s = try e.snapshot();
    try testing.expectEqual(snapshot.CursorStyle.bar, s.cursor.?.style);
    try testing.expect(!s.cursor.?.blinking);
    feed(e, "\x1b[3 q");
    s = try e.snapshot();
    try testing.expectEqual(snapshot.CursorStyle.underline, s.cursor.?.style);
    try testing.expect(s.cursor.?.blinking);
}

test "damage tracking marks only changed rows" {
    const e = try emu(10, 4);
    defer e.destroy();
    feed(e, "a\r\nb\r\nc");
    var s = try e.snapshot();
    try testing.expectEqual(snapshot.Damage.full, s.damage);
    s = try e.snapshot();
    try testing.expectEqual(snapshot.Damage.none, s.damage);
    feed(e, "\x1b[2;1HB");
    s = try e.snapshot();
    try testing.expectEqual(snapshot.Damage.partial, s.damage);
    try testing.expect(!s.lines[0].dirty);
    try testing.expect(s.lines[1].dirty);
    try testing.expect(!s.lines[3].dirty);
}

test "resize reflows soft-wrapped lines" {
    const e = try emu(10, 4);
    defer e.destroy();
    feed(e, "0123456789abcdefghij\r\nend");
    try expectRow(e, 0, "0123456789");
    try expectRow(e, 1, "abcdefghij");
    try e.resize(20, 4);
    try expectRow(e, 0, "0123456789abcdefghij");
    try expectRow(e, 1, "end");
    try e.resize(5, 6);
    try expectRow(e, 0, "01234");
    try expectRow(e, 3, "fghij");
    try expectRow(e, 4, "end");
}

test "mouse reporting modes and SGR encoding" {
    const e = try emu(80, 24);
    defer e.destroy();
    var buf: [64]u8 = undefined;
    const geo: input.Geometry = .{ .cell_width = 10, .cell_height = 20 };
    try testing.expect(input.encodeMouse(e, .{ .action = .press, .button = .left, .x = 5, .y = 5 }, geo, &buf) == null);
    feed(e, "\x1b[?1000h\x1b[?1006h");
    try testing.expect(e.mouseReporting());
    try testing.expectEqualStrings("\x1b[<0;3;2M", input.encodeMouse(e, .{ .action = .press, .button = .left, .x = 25, .y = 30 }, geo, &buf).?);
    try testing.expectEqualStrings("\x1b[<0;3;2m", input.encodeMouse(e, .{ .action = .release, .button = .left, .x = 25, .y = 30 }, geo, &buf).?);
    // Normal mode (1000) does not report motion.
    try testing.expect(input.encodeMouse(e, .{ .action = .motion, .x = 45, .y = 30 }, geo, &buf) == null);
    feed(e, "\x1b[?1003h");
    try testing.expectEqualStrings("\x1b[<35;5;2M", input.encodeMouse(e, .{ .action = .motion, .x = 45, .y = 30 }, geo, &buf).?);
    // Wheel with modifiers.
    try testing.expectEqualStrings("\x1b[<64;1;1M", input.encodeMouse(e, .{ .action = .press, .button = .wheel_up, .x = 1, .y = 1 }, geo, &buf).?);
    try testing.expectEqualStrings("\x1b[<20;1;1M", input.encodeMouse(e, .{ .action = .press, .button = .left, .mods = .{ .control = true, .shift = true }, .x = 1, .y = 1 }, geo, &buf).?);
    // X10 format (no 1006).
    feed(e, "\x1b[?1006l\x1b[?1003l\x1b[?1000h");
    try testing.expectEqualStrings("\x1b[M !!", input.encodeMouse(e, .{ .action = .press, .button = .left, .x = 1, .y = 1 }, geo, &buf).?);
}

test "wheel: alternate scroll in the alt screen, viewport scroll otherwise" {
    const e = try emu(10, 3);
    defer e.destroy();
    var lines_buf: [16]u8 = undefined;
    for (1..9) |i| feed(e, try std.fmt.bufPrint(&lines_buf, "l{d}\r\n", .{i}));
    var buf: [64]u8 = undefined;
    const geo: input.Geometry = .{ .cell_width = 10, .cell_height = 20 };
    try testing.expectEqual(input.WheelResult.scrolled, input.wheel(e, 2, .{ .x = 0, .y = 0 }, geo, &buf));
    try testing.expectEqual(@as(usize, 2), e.displayOffset());
    e.scrollToBottom();
    feed(e, "\x1b[?1049h");
    const r = input.wheel(e, 2, .{ .x = 0, .y = 0 }, geo, &buf);
    try testing.expectEqualStrings("\x1b[A\x1b[A", r.bytes);
    feed(e, "\x1b[?1h");
    try testing.expectEqualStrings("\x1bOB", input.wheel(e, -1, .{ .x = 0, .y = 0 }, geo, &buf).bytes);
}

test "paste wraps when bracketed" {
    // zeron view.rs `paste_wraps_when_bracketed`
    const plain = try input.pasteWith(gpa, "ls\n", false);
    defer gpa.free(plain);
    try testing.expectEqualStrings("ls\r", plain);
    const br = try input.pasteWith(gpa, "ls\n", true);
    defer gpa.free(br);
    try testing.expectEqualStrings("\x1b[200~ls\n\x1b[201~", br);
    // An embedded end marker cannot break out of the bracket.
    const evil = try input.pasteWith(gpa, "a\x1b[201~rm -rf /\n", true);
    defer gpa.free(evil);
    try testing.expect(std.mem.indexOf(u8, evil[6 .. evil.len - 6], "\x1b[201~") == null);

    const e = try emu(10, 2);
    defer e.destroy();
    feed(e, "\x1b[?2004h");
    const p = try input.paste(e, gpa, "x");
    defer gpa.free(p);
    try testing.expectEqualStrings("\x1b[200~x\x1b[201~", p);
}

test "focus reporting" {
    const e = try emu(10, 2);
    defer e.destroy();
    try testing.expect(input.focus(e, true) == null);
    feed(e, "\x1b[?1004h");
    try testing.expectEqualStrings("\x1b[I", input.focus(e, true).?);
    try testing.expectEqualStrings("\x1b[O", input.focus(e, false).?);
}

test "keys follow terminal modes through the emulator" {
    const keys = @import("keys.zig");
    const e = try emu(10, 2);
    defer e.destroy();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[A", keys.encode(e, .{ .key = "up" }, &buf).?);
    feed(e, "\x1b[?1h");
    try testing.expectEqualStrings("\x1bOA", keys.encode(e, .{ .key = "up" }, &buf).?);
    // Kitty keyboard protocol push (CSI > 1 u): disambiguate.
    feed(e, "\x1b[>1u");
    try testing.expectEqualStrings("\x1b[27u", keys.encode(e, .{ .key = "escape" }, &buf).?);
    feed(e, "\x1b[<u");
    try testing.expectEqualStrings("\x1b", keys.encode(e, .{ .key = "escape" }, &buf).?);
}

test "decset common set: origin, wraparound, insert, reverse video" {
    const e = try emu(10, 4);
    defer e.destroy();
    feed(e, "\x1b[?7l0123456789XYZ");
    try expectRow(e, 0, "012345678Z");
    feed(e, "\x1b[?7h\r\n\x1b[4hab\x1b[4l\rZ");
    try expectRow(e, 1, "Zb");
    feed(e, "\x1b[?5h");
    try testing.expect(e.mode(.reverse_colors));
    feed(e, "\x1b[2;3r\x1b[?6h\x1b[H*");
    try expectRow(e, 1, "*b");
}

test "osc 10/11/4 color queries report the theme palette" {
    const palette = @import("palette.zig");
    const e = try emu(10, 2);
    defer e.destroy();
    try e.setPalette(&palette.zeron_dark_fallback);
    try testing.expectEqualStrings("\x1b]11;rgb:0909/0909/0909\x1b\\", e.feed("\x1b]11;?\x1b\\"));
    try testing.expectEqualStrings("\x1b]10;rgb:e8e8/e8e8/eaea\x07", e.feed("\x1b]10;?\x07"));
    try testing.expectEqualStrings("\x1b]4;1;rgb:f8f8/7171/7171\x07", e.feed("\x1b]4;1;?\x07"));
}
