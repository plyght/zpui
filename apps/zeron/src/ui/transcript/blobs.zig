//! [wiring] Sidecar tool blobs — zeron `transcript.rs` `spawn_blob_fetch`,
//! `blob_detail`, the chip `affordances` and the "most recently requested
//! blob wins" detail upgrade. A truncated tool output / large diff carries a
//! `outputRef` / `diffRef`; "Show full output (12 KB)" fetches it
//! (`FetchToolBlob {blobRef}` → `{text}`) and the chip's open detail shows
//! the fetched payload (output capped at 400 lines) from then on. A failed
//! fetch re-arms as "Couldn't load full output — tap to retry".

const std = @import("std");
const zpui = @import("zpui");
const engine = @import("zeron_engine");
const rows = @import("rows.zig");

const Allocator = std.mem.Allocator;
const protocol = engine.protocol;
const ToolItem = rows.ToolItem;
const ToolDetail = rows.ToolDetail;

pub const full_output_max_lines: usize = 400;

pub const State = enum { loading, ready, failed };

pub const Blob = struct {
    state: State,
    /// Owns the fetched detail's memory (arena + diff patch sets).
    holder: ?*rows.EntryRows = null,
    detail: ?ToolDetail = null,
    /// Request recency (the latest clicked ref wins the detail slot).
    order: u64 = 0,

    fn deinit(b: *Blob, gpa: Allocator) void {
        if (b.holder) |h| {
            h.deinit(gpa);
            gpa.destroy(h);
        }
        b.holder = null;
    }
};

pub const Affordance = struct { blob_ref: []const u8, label: []const u8 };

pub const Blobs = struct {
    map: std.StringHashMapUnmanaged(Blob) = .empty,
    counter: u64 = 0,

    pub fn deinit(self: *Blobs, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(gpa);
            gpa.free(e.key_ptr.*);
        }
        self.map.deinit(gpa);
    }

    /// Mark `blob_ref` requested; true when a fetch must start (absent or
    /// failed). A ready ref only bumps its recency (the "show this one" toggle).
    pub fn request(self: *Blobs, gpa: Allocator, blob_ref: []const u8) bool {
        self.counter += 1;
        const gop = self.map.getOrPut(gpa, blob_ref) catch return false;
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, blob_ref) catch {
                _ = self.map.remove(blob_ref);
                return false;
            };
            gop.value_ptr.* = .{ .state = .loading, .order = self.counter };
            return true;
        }
        gop.value_ptr.order = self.counter;
        switch (gop.value_ptr.state) {
            .ready, .loading => return false,
            .failed => {
                gop.value_ptr.state = .loading;
                return true;
            },
        }
    }

    /// A fetch landed: `text` (null = failed) becomes the ref's detail.
    pub fn land(self: *Blobs, gpa: Allocator, blob_ref: []const u8, text: ?[]const u8) void {
        const b = self.map.getPtr(blob_ref) orelse return;
        b.deinit(gpa);
        b.detail = null;
        const t = text orelse {
            b.state = .failed;
            return;
        };
        const holder = gpa.create(rows.EntryRows) catch {
            b.state = .failed;
            return;
        };
        holder.* = .{ .arena = .init(gpa), .fingerprint = 0 };
        b.holder = holder;
        b.detail = blobDetail(gpa, holder, t, std.mem.endsWith(u8, blob_ref, ".diff")) catch null;
        b.state = if (b.detail != null) .ready else .failed;
    }

    /// The chip's effective body: the most recently requested ready blob,
    /// else the doc-resident detail.
    pub fn effective(self: *const Blobs, t: ToolItem) ?ToolDetail {
        var best: ?Blob = null;
        for ([_]?[]const u8{ t.diff_ref, t.output_ref }) |r| if (r) |ref| if (self.map.get(ref)) |b| if (b.state == .ready) {
            if (best == null or b.order > best.?.order) best = b;
        };
        if (best) |b| return b.detail;
        return t.body;
    }

    fn shownRef(self: *const Blobs, t: ToolItem) ?[]const u8 {
        var best: ?[]const u8 = null;
        var order: u64 = 0;
        for ([_]?[]const u8{ t.diff_ref, t.output_ref }) |r| if (r) |ref| if (self.map.get(ref)) |b| if (b.state == .ready and (best == null or b.order > order)) {
            best = ref;
            order = b.order;
        };
        return best;
    }

    /// The fetch affordance under an open detail: diff first, then output; a
    /// fetched ref hands it to the next unfetched one.
    pub fn affordance(self: *const Blobs, t: ToolItem, buf: []u8) ?Affordance {
        const shown = self.shownRef(t);
        const Cand = struct { ref: ?[]const u8, what: []const u8, bytes: ?u64 };
        for ([_]Cand{ .{ .ref = t.diff_ref, .what = "diff", .bytes = null }, .{ .ref = t.output_ref, .what = "output", .bytes = t.output_bytes } }) |c| {
            const ref = c.ref orelse continue;
            const label: []const u8 = if (self.map.get(ref)) |b| switch (b.state) {
                .ready => blk: {
                    if (shown != null and std.mem.eql(u8, shown.?, ref)) continue;
                    break :blk std.fmt.bufPrint(buf, "Show full {s}", .{c.what}) catch "Show full";
                },
                .loading => std.fmt.bufPrint(buf, "Loading full {s}\u{2026}", .{c.what}) catch "Loading…",
                .failed => std.fmt.bufPrint(buf, "Couldn't load full {s} \u{2014} tap to retry", .{c.what}) catch "Retry",
            } else if (c.bytes) |b|
                (if (b < 1024) std.fmt.bufPrint(buf, "Show full {s} ({d} B)", .{ c.what, b }) else std.fmt.bufPrint(buf, "Show full {s} ({d} KB)", .{ c.what, (b + 1023) / 1024 })) catch "Show full"
            else
                std.fmt.bufPrint(buf, "Show full {s}", .{c.what}) catch "Show full";
            return .{ .blob_ref = ref, .label = label };
        }
        return null;
    }
};

/// `blob_detail`: a diff blob is a `ToolDiff` JSON; anything else is output
/// text capped at `full_output_max_lines`.
pub fn blobDetail(gpa: Allocator, holder: *rows.EntryRows, text: []const u8, is_diff: bool) !?ToolDetail {
    const a = holder.arena.allocator();
    if (is_diff) {
        const d = std.json.parseFromSliceLeaky(protocol.ToolDiff, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
        const tool: protocol.MessagePart.Tool = .{ .id = "blob", .call = .{ .applyPatch = .{} }, .diff = d };
        return rows.toolDetail(gpa, a, holder, tool);
    }
    return rows.outputDetail(a, text, full_output_max_lines);
}

const testing = std.testing;

test "blob requests, landing and the affordance ladder" {
    const gpa = testing.allocator;
    var b: Blobs = .{};
    defer b.deinit(gpa);
    const t: ToolItem = .{ .part_id = "p", .label = "Run", .detail = "", .icon = .terminal, .output_ref = "c/o1.txt", .output_bytes = 12_000 };
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("Show full output (12 KB)", b.affordance(t, &buf).?.label);
    try testing.expect(b.request(gpa, "c/o1.txt"));
    try testing.expect(!b.request(gpa, "c/o1.txt"));
    try testing.expectEqualStrings("Loading full output\u{2026}", b.affordance(t, &buf).?.label);
    b.land(gpa, "c/o1.txt", null);
    try testing.expectEqualStrings("Couldn't load full output \u{2014} tap to retry", b.affordance(t, &buf).?.label);
    try testing.expect(b.request(gpa, "c/o1.txt"));
    b.land(gpa, "c/o1.txt", "line 1\nline 2\n\n");
    try testing.expect(b.affordance(t, &buf) == null);
    const d = b.effective(t).?;
    try testing.expectEqual(@as(usize, 2), d.output.lines.len);
    try testing.expectEqualStrings("line 2", d.output.lines[1]);
}
