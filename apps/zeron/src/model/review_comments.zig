//! `ReviewCommentStore`: the staged review comments per composer key — zeron
//! `AppState::review_comments` / `review_comment_flushes` (`state.rs`).
//!
//! In memory only, exactly like Rust: the changes pane and the file editor
//! write here, the composer reads the selected chat's set, folds it into the
//! next prompt (`comments.withComments`) and takes it. Nothing is persisted
//! to disk or the engine; a failed send restores the taken set.
//!
//! Editor comments that cite a buffer revision not yet on disk hold a *flush*
//! (one per file surface): the composer blocks sends until every surface
//! waiting on a workspace write finished or cancelled.
//!
//! ```zig
//! const store = state.read(cx).review_comments;
//! const id = try store.update(cx, ReviewCommentStore.add, .{ key, .{ .path = "a.rs", .line = 3, .body = "why?", .source = .{ .diff = .{ .side = .old } } } });
//! store.read(cx).comments(key)            // []const comments.ReviewComment
//! var taken = store.update(cx, ReviewCommentStore.take, .{key}); defer taken.deinit(gpa);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const comments = @import("comments.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;

pub const ReviewComment = comments.ReviewComment;
pub const CommentSource = comments.CommentSource;
pub const CommentSide = comments.CommentSide;

/// A comment to stage (the store mints the id and copies every string).
pub const NewComment = struct {
    path: []const u8,
    line: u32,
    body: []const u8,
    source: CommentSource,
};

/// An owned list of comments (`take`'s result): free with `deinit`.
pub const OwnedComments = struct {
    items: []ReviewComment = &.{},

    pub fn deinit(self: *OwnedComments, gpa: Allocator) void {
        for (self.items) |*c| freeComment(gpa, c);
        gpa.free(self.items);
        self.* = .{};
    }
};

/// The zpui global through which surfaces that do not hold the `AppState`
/// (the file editor) reach the store.
pub const Global = struct { store: zpui.WeakEntity(ReviewCommentStore) };

/// The store installed by the running `AppState`, if any.
pub fn current(app: *App) ?Entity(ReviewCommentStore) {
    if (app.shutting_down) return null;
    const g = app.tryGlobal(Global) orelse return null;
    if (!g.store.isAlive(app)) return null;
    return .{ .id = g.store.id };
}

const List = std.ArrayList(ReviewComment);

/// The composer's send-path fold: `text` with `key`'s staged comments
/// appended (`with_comments`), without taking them — the composer clears the
/// set once the send went through, so a failed send never loses a note.
pub fn foldPrompt(gpa: Allocator, store: *const ReviewCommentStore, key: []const u8, text: []const u8) Allocator.Error![]u8 {
    return comments.withComments(gpa, text, store.comments(key));
}

/// `comment_strip_height`: the composer's "N comments" chip row.
pub fn stripHeight(count: usize) f32 {
    if (count == 0) return 0;
    return strip_pad_top + badge_height;
}

/// `badges::BADGE_HEIGHT` / the composer's `STRIP_PAD_TOP`.
pub const badge_height: f32 = 24;
pub const strip_pad_top: f32 = 12;
pub const strip_pad_x: f32 = 16;

pub const ReviewCommentStore = struct {
    gpa: Allocator,
    io: ?std.Io,
    by_key: std.StringHashMapUnmanaged(List) = .empty,
    /// key → file-surface sources still waiting on a workspace write.
    flushes: std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(u64, void)) = .empty,
    /// `AppState::composer_key()`: the selected chat id, "" on the canvas.
    composer_key: std.ArrayList(u8) = .empty,
    /// Fallback id counter when no `Io` is available (tests).
    next_id: u64 = 1,

    pub fn init(io: ?std.Io, cx: *Context(ReviewCommentStore)) ReviewCommentStore {
        return .{ .gpa = cx.gpa(), .io = io };
    }

    pub fn deinit(self: *ReviewCommentStore, _: *App) void {
        var it = self.by_key.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |*c| freeComment(self.gpa, c);
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.by_key.deinit(self.gpa);
        var fit = self.flushes.iterator();
        while (fit.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.flushes.deinit(self.gpa);
        self.composer_key.deinit(self.gpa);
    }

    /// The composer key comments stage onto (the selected chat, "" for none).
    pub fn composerKey(self: *const ReviewCommentStore) []const u8 {
        return self.composer_key.items;
    }

    pub fn setComposerKey(self: *ReviewCommentStore, key: []const u8, cx: *Context(ReviewCommentStore)) void {
        if (std.mem.eql(u8, key, self.composer_key.items)) return;
        self.composer_key.clearRetainingCapacity();
        self.composer_key.appendSlice(self.gpa, key) catch {};
        cx.notify();
    }

    /// `review_comments(key)`.
    pub fn comments(self: *const ReviewCommentStore, key: []const u8) []const ReviewComment {
        return if (self.by_key.getPtr(key)) |l| l.items else &.{};
    }

    pub fn find(self: *const ReviewCommentStore, key: []const u8, id: []const u8) ?*const ReviewComment {
        for (self.comments(key)) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    fn findMut(self: *ReviewCommentStore, key: []const u8, id: []const u8) ?*ReviewComment {
        const l = self.by_key.getPtr(key) orelse return null;
        for (l.items) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    fn mintId(self: *ReviewCommentStore, buf: *[36]u8) []const u8 {
        if (self.io) |io| {
            var b: [16]u8 = undefined;
            io.random(&b);
            b[6] = (b[6] & 0x0f) | 0x40;
            b[8] = (b[8] & 0x3f) | 0x80;
            const hex = "0123456789abcdef";
            var o: usize = 0;
            for (b, 0..) |byte, i| {
                if (i == 4 or i == 6 or i == 8 or i == 10) {
                    buf[o] = '-';
                    o += 1;
                }
                buf[o] = hex[byte >> 4];
                buf[o + 1] = hex[byte & 15];
                o += 2;
            }
            return buf[0..36];
        }
        defer self.next_id += 1;
        return std.fmt.bufPrint(buf, "comment-{d}", .{self.next_id}) catch unreachable;
    }

    /// `add_review_comment`: stage `c` under `key`; returns the new id
    /// (owned by the store).
    pub fn add(self: *ReviewCommentStore, key: []const u8, c: NewComment, cx: *Context(ReviewCommentStore)) Allocator.Error![]const u8 {
        var buf: [36]u8 = undefined;
        const comment = try dupeComment(self.gpa, .{ .id = self.mintId(&buf), .path = c.path, .line = c.line, .body = c.body, .source = c.source });
        try self.push(key, comment);
        cx.notify();
        return comment.id;
    }

    /// Re-stage an existing comment as is (a failed send's hand-back).
    pub fn restore(self: *ReviewCommentStore, key: []const u8, c: *const ReviewComment, cx: *Context(ReviewCommentStore)) Allocator.Error!void {
        try self.push(key, try dupeComment(self.gpa, c.*));
        cx.notify();
    }

    fn push(self: *ReviewCommentStore, key: []const u8, comment: ReviewComment) Allocator.Error!void {
        var owned = comment;
        errdefer freeComment(self.gpa, &owned);
        const gop = try self.by_key.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
                self.by_key.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.gpa, owned);
    }

    /// `remove_review_comment`: an emptied key also drops its flushes.
    pub fn remove(self: *ReviewCommentStore, key: []const u8, id: []const u8, cx: *Context(ReviewCommentStore)) void {
        const l = self.by_key.getPtr(key) orelse return;
        var i: usize = 0;
        while (i < l.items.len) {
            if (std.mem.eql(u8, l.items[i].id, id)) {
                var c = l.orderedRemove(i);
                freeComment(self.gpa, &c);
            } else i += 1;
        }
        if (l.items.len == 0) {
            self.dropKey(key);
            self.dropFlushes(key);
        }
        cx.notify();
    }

    /// `update_review_comment_body`: never recreates a comment that was
    /// removed or sent meanwhile.
    pub fn updateBody(self: *ReviewCommentStore, key: []const u8, id: []const u8, body: []const u8, cx: *Context(ReviewCommentStore)) void {
        const c = self.findMut(key, id) orelse return;
        const owned = self.gpa.dupe(u8, body) catch return;
        self.gpa.free(c.body);
        c.body = owned;
        cx.notify();
    }

    pub fn updateLine(self: *ReviewCommentStore, key: []const u8, id: []const u8, line: u32, cx: *Context(ReviewCommentStore)) void {
        const c = self.findMut(key, id) orelse return;
        if (c.line == line) return;
        c.line = line;
        cx.notify();
    }

    /// `rename_review_comment_path`: file comments follow a renamed document.
    pub fn renamePath(self: *ReviewCommentStore, key: []const u8, old_path: []const u8, new_path: []const u8, cx: *Context(ReviewCommentStore)) void {
        const l = self.by_key.getPtr(key) orelse return;
        var changed = false;
        for (l.items) |*c| if (c.isFile() and std.mem.eql(u8, c.path, old_path)) {
            const owned = self.gpa.dupe(u8, new_path) catch continue;
            self.gpa.free(c.path);
            c.path = owned;
            changed = true;
        };
        if (changed) cx.notify();
    }

    /// `take_review_comments`: the staged set, removed (and its flushes).
    pub fn take(self: *ReviewCommentStore, key: []const u8, cx: *Context(ReviewCommentStore)) OwnedComments {
        self.dropFlushes(key);
        const kv = self.by_key.fetchRemove(key) orelse return .{};
        self.gpa.free(kv.key);
        var l = kv.value;
        cx.notify();
        return .{ .items = l.toOwnedSlice(self.gpa) catch blk: {
            for (l.items) |*c| freeComment(self.gpa, c);
            l.deinit(self.gpa);
            break :blk &.{};
        } };
    }

    /// `purge_review_comments` (a deleted chat).
    pub fn purge(self: *ReviewCommentStore, key: []const u8, cx: *Context(ReviewCommentStore)) void {
        self.dropFlushes(key);
        self.dropKey(key);
        cx.notify();
    }

    pub fn beginFlush(self: *ReviewCommentStore, key: []const u8, source: u64, cx: *Context(ReviewCommentStore)) void {
        const gop = self.flushes.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch {
                self.flushes.removeByPtr(gop.key_ptr);
                return;
            };
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.put(self.gpa, source, {}) catch {};
        cx.notify();
    }

    pub fn finishFlush(self: *ReviewCommentStore, key: []const u8, source: u64, cx: *Context(ReviewCommentStore)) void {
        const set = self.flushes.getPtr(key) orelse return;
        _ = set.remove(source);
        if (set.count() == 0) self.dropFlushes(key);
        cx.notify();
    }

    pub fn flushPending(self: *const ReviewCommentStore, key: []const u8) bool {
        return self.flushes.contains(key);
    }

    fn dropKey(self: *ReviewCommentStore, key: []const u8) void {
        const kv = self.by_key.fetchRemove(key) orelse return;
        var l = kv.value;
        for (l.items) |*c| freeComment(self.gpa, c);
        l.deinit(self.gpa);
        self.gpa.free(kv.key);
    }

    fn dropFlushes(self: *ReviewCommentStore, key: []const u8) void {
        const kv = self.flushes.fetchRemove(key) orelse return;
        var set = kv.value;
        set.deinit(self.gpa);
        self.gpa.free(kv.key);
    }
};

fn dupeComment(gpa: Allocator, c: ReviewComment) Allocator.Error!ReviewComment {
    const id = try gpa.dupe(u8, c.id);
    errdefer gpa.free(id);
    const path = try gpa.dupe(u8, c.path);
    errdefer gpa.free(path);
    const body = try gpa.dupe(u8, c.body);
    errdefer gpa.free(body);
    const source: CommentSource = switch (c.source) {
        .file => .file,
        .diff => |d| .{ .diff = .{ .side = d.side, .old_path = if (d.old_path) |o| try gpa.dupe(u8, o) else null } },
    };
    return .{ .id = id, .path = path, .line = c.line, .body = body, .source = source };
}

fn freeComment(gpa: Allocator, c: *ReviewComment) void {
    gpa.free(c.id);
    gpa.free(c.path);
    gpa.free(c.body);
    switch (c.source) {
        .diff => |d| if (d.old_path) |o| gpa.free(o),
        .file => {},
    }
}

// ---------------------------------------------------------------------------
// Tests (zeron `state.rs` review-comment tests)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "review comments: body updates are scoped and keep current metadata" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const store = try app.newWith(ReviewCommentStore, ReviewCommentStore.init, .{null});
    defer store.release(app);
    const original: NewComment = .{ .path = "a.rs", .line = 2, .body = "Original", .source = .file };
    const id1 = try store.update(app, ReviewCommentStore.add, .{ "chat-1", original });
    const id_owned = try testing.allocator.dupe(u8, id1);
    defer testing.allocator.free(id_owned);
    _ = try store.update(app, ReviewCommentStore.add, .{ "chat-2", original });
    store.update(app, ReviewCommentStore.beginFlush, .{ "chat-1", 1 });
    store.update(app, ReviewCommentStore.updateLine, .{ "chat-1", id_owned, 9 });
    store.update(app, ReviewCommentStore.renamePath, .{ "chat-1", "a.rs", "renamed.rs" });
    store.update(app, ReviewCommentStore.updateBody, .{ "chat-1", id_owned, "Revised" });
    const c1 = store.read(app).comments("chat-1");
    try testing.expectEqual(@as(usize, 1), c1.len);
    try testing.expectEqualStrings("renamed.rs", c1[0].path);
    try testing.expectEqual(@as(u32, 9), c1[0].line);
    try testing.expectEqualStrings("Revised", c1[0].body);
    const c2 = store.read(app).comments("chat-2");
    try testing.expectEqualStrings("a.rs", c2[0].path);
    try testing.expectEqualStrings("Original", c2[0].body);
    try testing.expect(store.read(app).flushPending("chat-1"));
    store.update(app, ReviewCommentStore.remove, .{ "chat-1", id_owned });
    store.update(app, ReviewCommentStore.updateBody, .{ "chat-1", id_owned, "Stale" });
    store.update(app, ReviewCommentStore.updateBody, .{ "missing-chat", id_owned, "Stale" });
    try testing.expectEqual(@as(usize, 0), store.read(app).comments("chat-1").len);
    try testing.expectEqual(@as(usize, 0), store.read(app).comments("missing-chat").len);
    // Removing the last comment of a key drops its flush.
    try testing.expect(!store.read(app).flushPending("chat-1"));
}

test "review comments: flush waits for every file surface; take clears" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const store = try app.newWith(ReviewCommentStore, ReviewCommentStore.init, .{null});
    defer store.release(app);
    store.update(app, ReviewCommentStore.beginFlush, .{ "chat-1", 1 });
    store.update(app, ReviewCommentStore.beginFlush, .{ "chat-1", 2 });
    try testing.expect(store.read(app).flushPending("chat-1"));
    store.update(app, ReviewCommentStore.finishFlush, .{ "chat-1", 1 });
    try testing.expect(store.read(app).flushPending("chat-1"));
    store.update(app, ReviewCommentStore.finishFlush, .{ "chat-1", 2 });
    try testing.expect(!store.read(app).flushPending("chat-1"));

    _ = try store.update(app, ReviewCommentStore.add, .{ "k", NewComment{ .path = "new.rs", .line = 7, .body = "Revised\nMore detail", .source = .{ .diff = .{ .side = .old, .old_path = "old.rs" } } } });
    store.update(app, ReviewCommentStore.beginFlush, .{ "k", 3 });
    var taken = store.update(app, ReviewCommentStore.take, .{"k"});
    defer taken.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), taken.items.len);
    try testing.expectEqualStrings("old.rs", taken.items[0].citePath());
    try testing.expect(!store.read(app).flushPending("k"));
    try testing.expectEqual(@as(usize, 0), store.read(app).comments("k").len);
    const prompt = try comments.withComments(testing.allocator, "", taken.items);
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "- old.rs:7 (L): Revised\n  More detail") != null);
    // A failed send hands the set back.
    try store.update(app, ReviewCommentStore.restore, .{ "k", &taken.items[0] });
    try testing.expectEqualStrings(taken.items[0].id, store.read(app).comments("k")[0].id);
}
