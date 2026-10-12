//! Windows "open file" dialog (gpui_windows `prompt_for_paths`): the common
//! `GetOpenFileNameW` dialog for files, `SHBrowseForFolderW` for folders. Both block
//! (they run their own modal loop), so each runs on its own thread with COM initialized
//! and the answer is posted back to the main thread through the dispatcher; zpui's own
//! loop and frames keep going while the dialog is up.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const w = @import("win32.zig");

const WINAPI = w.WINAPI;

const OPENFILENAMEW = extern struct {
    lStructSize: w.DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?w.HWND = null,
    hInstance: ?w.HINSTANCE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: w.DWORD = 0,
    nFilterIndex: w.DWORD = 0,
    lpstrFile: [*]u16,
    nMaxFile: w.DWORD,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: w.DWORD = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: w.DWORD = 0,
    nFileOffset: w.WORD = 0,
    nFileExtension: w.WORD = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: w.LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: w.DWORD = 0,
    FlagsEx: w.DWORD = 0,
};

const BROWSEINFOW = extern struct {
    hwndOwner: ?w.HWND = null,
    pidlRoot: ?*const anyopaque = null,
    pszDisplayName: ?[*]u16 = null,
    lpszTitle: ?[*:0]const u16 = null,
    ulFlags: c_uint = 0,
    lpfn: ?*const anyopaque = null,
    lParam: w.LPARAM = 0,
    iImage: c_int = 0,
};

const OFN_NOCHANGEDIR: w.DWORD = 0x8;
const OFN_HIDEREADONLY: w.DWORD = 0x4;
const OFN_ALLOWMULTISELECT: w.DWORD = 0x200;
const OFN_PATHMUSTEXIST: w.DWORD = 0x800;
const OFN_FILEMUSTEXIST: w.DWORD = 0x1000;
const OFN_EXPLORER: w.DWORD = 0x80000;
const BIF_RETURNONLYFSDIRS: c_uint = 0x1;
const BIF_NEWDIALOGSTYLE: c_uint = 0x40;

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(WINAPI) w.BOOL;
extern "shell32" fn SHBrowseForFolderW(bi: *BROWSEINFOW) callconv(WINAPI) ?*anyopaque;
extern "shell32" fn SHGetPathFromIDListW(pidl: *anyopaque, path: [*]u16) callconv(WINAPI) w.BOOL;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(WINAPI) void;

/// Owned dialog result, delivered on the main thread (null paths = canceled).
const Job = struct {
    gpa: Allocator,
    dispatcher: platform.Dispatcher,
    done: platform.PathsCallback,
    /// Options with their strings in `arena`.
    options: platform.PathPromptOptions,
    arena: std.heap.ArenaAllocator,
    paths: ?[][]const u8 = null,

    fn main(self: *Job) void {
        _ = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED | w.COINIT_DISABLE_OLE1DDE);
        defer w.CoUninitialize();
        self.paths = run(self.arena.allocator(), self.options) catch null;
        self.dispatcher.dispatchOnMainThread(.{ .ctx = self, .run = runMain, .drop = drop }, .high);
    }

    fn runMain(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        defer drop(ctx);
        if (self.paths) |ps| self.done.func(self.done.ctx, ps) else self.done.func(self.done.ctx, null);
    }

    fn drop(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Start a dialog; `done` runs on the main thread exactly once.
pub fn prompt(gpa: Allocator, dispatcher: platform.Dispatcher, options: platform.PathPromptOptions, done: platform.PathsCallback) void {
    const job = gpa.create(Job) catch return done.func(done.ctx, null);
    job.* = .{ .gpa = gpa, .dispatcher = dispatcher, .done = done, .options = options, .arena = .init(gpa) };
    job.options = copyOptions(job.arena.allocator(), options) catch return fail(job, done);
    const thread = std.Thread.spawn(.{}, Job.main, .{job}) catch return fail(job, done);
    thread.detach();
}

fn fail(job: *Job, done: platform.PathsCallback) void {
    Job.drop(job);
    done.func(done.ctx, null);
}

fn copyOptions(a: Allocator, options: platform.PathPromptOptions) !platform.PathPromptOptions {
    var o = options;
    if (options.prompt) |s| o.prompt = try a.dupe(u8, s);
    if (options.title) |s| o.title = try a.dupe(u8, s);
    if (options.directory) |s| o.directory = try a.dupe(u8, s);
    if (options.filter_label) |s| o.filter_label = try a.dupe(u8, s);
    const exts = try a.alloc([]const u8, options.extensions.len);
    for (exts, options.extensions) |*d, e| d.* = try a.dupe(u8, e);
    o.extensions = exts;
    return o;
}

/// Blocking: the chosen paths (in `a`), null when canceled.
fn run(a: Allocator, options: platform.PathPromptOptions) !?[][]const u8 {
    if (options.directories and !options.files) return browseFolder(a, options);
    const title = if (options.title) |t| try w.utf8ToWide(a, t) else null;
    const dir = if (options.directory) |d| try w.utf8ToWide(a, d) else null;
    const filter = try filterString(a, options);
    const buf = try a.alloc(u16, 32 * 1024);
    @memset(buf, 0);
    var ofn: OPENFILENAMEW = .{
        .lpstrFile = buf.ptr,
        .nMaxFile = @intCast(buf.len),
        .lpstrFilter = if (filter) |f| f.ptr else null,
        .nFilterIndex = if (filter != null) 1 else 0,
        .lpstrInitialDir = if (dir) |d| d.ptr else null,
        .lpstrTitle = if (title) |t| t.ptr else null,
        .Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_HIDEREADONLY |
            (if (options.multiple) OFN_ALLOWMULTISELECT else 0),
    };
    if (GetOpenFileNameW(&ofn) == 0) return null;
    return try parseFileBuffer(a, buf);
}

/// `Label\0*.a;*.b\0All Files\0*.*\0\0`, or null without extensions.
fn filterString(a: Allocator, options: platform.PathPromptOptions) !?[:0]u16 {
    if (options.extensions.len == 0) return null;
    var s: std.Io.Writer.Allocating = .init(a);
    try s.writer.print("{s}", .{options.filter_label orelse "Files"});
    try s.writer.writeByte(0);
    for (options.extensions, 0..) |ext, i| try s.writer.print("{s}*.{s}", .{ if (i > 0) ";" else "", ext });
    try s.writer.writeByte(0);
    try s.writer.writeAll("All Files");
    try s.writer.writeByte(0);
    try s.writer.writeAll("*.*");
    try s.writer.writeByte(0);
    // utf8ToWide stops at nothing: embedded NULs come through, plus the final one.
    return try w.utf8ToWide(a, s.written());
}

/// The explorer-style result: one full path, or (multi-select) the folder followed by
/// file names, each NUL-terminated, ending with an empty string.
pub fn parseFileBuffer(a: Allocator, buf: []const u16) ![][]const u8 {
    var parts: std.ArrayList([]const u16) = .empty;
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) {
        const start = i;
        while (i < buf.len and buf[i] != 0) i += 1;
        try parts.append(a, buf[start..i]);
        i += 1;
    }
    var out: std.ArrayList([]const u8) = .empty;
    if (parts.items.len == 0) return out.toOwnedSlice(a);
    if (parts.items.len == 1) {
        try out.append(a, try toUtf8(a, parts.items[0]));
        return out.toOwnedSlice(a);
    }
    const dir = try toUtf8(a, parts.items[0]);
    for (parts.items[1..]) |name| {
        const n = try toUtf8(a, name);
        try out.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ dir, if (std.mem.endsWith(u8, dir, "\\")) "" else "\\", n }));
    }
    return out.toOwnedSlice(a);
}

fn toUtf8(a: Allocator, s: []const u16) ![]const u8 {
    const out = try a.alloc(u8, s.len * 3);
    return w.wideToUtf8Buf(out, s);
}

fn browseFolder(a: Allocator, options: platform.PathPromptOptions) !?[][]const u8 {
    const title = if (options.title) |t| try w.utf8ToWide(a, t) else null;
    var bi: BROWSEINFOW = .{
        .lpszTitle = if (title) |t| t.ptr else null,
        .ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
    };
    const pidl = SHBrowseForFolderW(&bi) orelse return null;
    defer CoTaskMemFree(pidl);
    var path: [1024]u16 = @splat(0);
    if (SHGetPathFromIDListW(pidl, &path) == 0) return null;
    const len = std.mem.indexOfScalar(u16, &path, 0) orelse path.len;
    const out = try a.alloc([]const u8, 1);
    out[0] = try toUtf8(a, path[0..len]);
    return out;
}

test "explorer multi-select buffer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Apps\\code.exe") ++ [_]u16{ 0, 0 };
    const one = try parseFileBuffer(a, &single);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("C:\\Apps\\code.exe", one[0]);
    const multi = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Apps") ++ [_]u16{0} ++ std.unicode.utf8ToUtf16LeStringLiteral("a.exe") ++ [_]u16{0} ++ std.unicode.utf8ToUtf16LeStringLiteral("b.exe") ++ [_]u16{ 0, 0 };
    const two = try parseFileBuffer(a, &multi);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("C:\\Apps\\b.exe", two[1]);
}
