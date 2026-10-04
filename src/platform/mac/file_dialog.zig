//! macOS native "open file" dialog (gpui_macos `prompt_for_paths`): an
//! `NSOpenPanel` run with `beginWithCompletionHandler:`, so the main run loop
//! (and zpui's frames) keep going while it is up. The completion handler is an
//! Objective-C block built by hand: a stack block literal whose descriptor
//! covers the captured context, which `Block_copy` (done by AppKit) moves to the
//! heap byte for byte. Also the pasteboard image reader (PNG directly, TIFF
//! converted to PNG through `NSBitmapImageRep`).

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const pf = @import("../platform.zig");

const id = objc.id;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;

/// `NSModalResponseOK`.
const modal_response_ok: NSInteger = 1;

extern "c" const _NSConcreteStackBlock: anyopaque;

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// Layout of a block literal (clang ABI) plus our captured fields.
const CompletionBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const fn (block: *const CompletionBlock, result: NSInteger) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    // Captures (copied verbatim by Block_copy).
    state: *State,
};

const descriptor: BlockDescriptor = .{ .size = @sizeOf(CompletionBlock) };

const State = struct {
    gpa: std.mem.Allocator,
    panel: id,
    done: pf.PathsCallback,
};

fn onComplete(block: *const CompletionBlock, result: NSInteger) callconv(.c) void {
    const state = block.state;
    defer {
        state.panel.release();
        state.gpa.destroy(state);
    }
    if (result != modal_response_ok) return state.done.func(state.done.ctx, null);
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const urls = state.panel.msg(?id, "URLs", .{}) orelse return state.done.func(state.done.ctx, null);
    const n = ak.arrayCount(urls);
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) {
        const url = ak.arrayAt(urls, i);
        const path = url.msg(?id, "path", .{}) orelse continue;
        const bytes = arena.dupe(u8, ak.stringBytes(path)) catch continue;
        paths.append(arena, bytes) catch continue;
    }
    state.done.func(state.done.ctx, paths.items);
}

/// Shows an `NSOpenPanel`; `done` runs on the main thread when it closes.
pub fn prompt(gpa: std.mem.Allocator, options: pf.PathPromptOptions, done: pf.PathsCallback) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const panel = ak.class("NSOpenPanel").msg(?id, "openPanel", .{}) orelse return done.func(done.ctx, null);
    _ = panel.retain();
    panel.msg(void, "setCanChooseDirectories:", .{objc.toBOOL(options.directories)});
    panel.msg(void, "setCanChooseFiles:", .{objc.toBOOL(options.files)});
    panel.msg(void, "setAllowsMultipleSelection:", .{objc.toBOOL(options.multiple)});
    panel.msg(void, "setCanCreateDirectories:", .{objc.toBOOL(true)});
    panel.msg(void, "setResolvesAliases:", .{objc.toBOOL(false)});
    if (options.prompt) |p| panel.msg(void, "setPrompt:", .{ak.nsString(p)});
    if (options.title) |t| panel.msg(void, "setMessage:", .{ak.nsString(t)});
    const state = gpa.create(State) catch {
        panel.release();
        return done.func(done.ctx, null);
    };
    state.* = .{ .gpa = gpa, .panel = panel, .done = done };
    const block: CompletionBlock = .{
        .isa = &_NSConcreteStackBlock,
        .flags = 0,
        .invoke = onComplete,
        .descriptor = &descriptor,
        .state = state,
    };
    panel.msg(void, "beginWithCompletionHandler:", .{@as(*const anyopaque, @ptrCast(&block))});
}

/// The general pasteboard's image as PNG (or the raw TIFF if conversion fails).
pub fn readClipboardImage(gpa: std.mem.Allocator) ?pf.ClipboardImage {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const pb = ak.class("NSPasteboard").msg(id, "generalPasteboard", .{});
    if (pb.msg(?id, "dataForType:", .{ak.nsString("public.png")})) |data| {
        return copyData(gpa, data, .png);
    }
    const tiff = pb.msg(?id, "dataForType:", .{ak.nsString("public.tiff")}) orelse return null;
    // TIFF → PNG (agents and zpui's decoders take PNG; gpui keeps TIFF and decodes it).
    if (ak.class("NSBitmapImageRep").msg(?id, "imageRepWithData:", .{tiff})) |rep| {
        const props = ak.class("NSDictionary").msg(id, "dictionary", .{});
        // NSBitmapImageFileTypePNG = 4
        if (rep.msg(?id, "representationUsingType:properties:", .{ @as(NSUInteger, 4), props })) |png| {
            return copyData(gpa, png, .png);
        }
    }
    return copyData(gpa, tiff, .tiff);
}

fn copyData(gpa: std.mem.Allocator, data: id, format: pf.ClipboardImageFormat) ?pf.ClipboardImage {
    const len = data.msg(NSUInteger, "length", .{});
    if (len == 0) return null;
    const ptr = data.msg(?[*]const u8, "bytes", .{}) orelse return null;
    const bytes = gpa.dupe(u8, ptr[0..len]) catch return null;
    return .{ .format = format, .bytes = bytes };
}
