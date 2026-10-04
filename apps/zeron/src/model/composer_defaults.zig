//! Sticky composer defaults — `{data_dir}/composer-defaults.json`, port of
//! zeron `crates/ui/src/settings/composer.rs` (the model picker's and the
//! new-session canvas' "remember my last picks" data source): last harness,
//! last model per harness (id + label), reasoning per model, model option
//! picks per model, the label cache, last device/project, and favorites.
//! Written synchronously (atomic temp + rename) on every pick; corrupt or
//! missing files fall back to defaults. Harness-keyed maps use the harness'
//! wire id as the JSON key (serde's `HashMap<HarnessId, _>`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const protocol = @import("zeron_engine").protocol;

pub const file_name = "composer-defaults.json";

const HarnessId = protocol.HarnessId;
const ReasoningLevel = protocol.ReasoningLevel;

/// Option id → choice id (the `ChatConfig.modelOptions` shape).
pub const ModelOptions = protocol.JsonMap;

pub const RememberedModel = struct { id: []const u8, label: []const u8 };
pub const FavoriteModel = struct { harness: HarnessId, model: []const u8 };

pub const ComposerDefaults = struct {
    harness: ?HarnessId = null,
    modelByHarness: json.ArrayHashMap(RememberedModel) = .{},
    reasoning: ?ReasoningLevel = null,
    reasoningByModel: json.ArrayHashMap(json.ArrayHashMap(ReasoningLevel)) = .{},
    modelOptionsByModel: json.ArrayHashMap(json.ArrayHashMap(ModelOptions)) = .{},
    modelLabels: json.ArrayHashMap([]const u8) = .{},
    device: ?[]const u8 = null,
    project: ?[]const u8 = null,
    noProject: bool = false,
    favorites: []const FavoriteModel = &.{},

    pub fn modelFor(self: *const ComposerDefaults, harness: HarnessId) ?RememberedModel {
        return self.modelByHarness.map.get(@tagName(harness));
    }

    /// Remember a pick (`saveDefaults({ harness, modelByHarness })`).
    pub fn rememberModel(self: *ComposerDefaults, a: Allocator, harness: HarnessId, id: []const u8, label: []const u8) !void {
        self.harness = harness;
        try self.modelByHarness.map.put(a, @tagName(harness), .{ .id = try a.dupe(u8, id), .label = try a.dupe(u8, label) });
    }

    pub fn modelOptionsFor(self: *const ComposerDefaults, harness: HarnessId, model: []const u8) ?*const ModelOptions {
        const per = self.modelOptionsByModel.map.getPtr(@tagName(harness)) orelse return null;
        return per.map.getPtr(model);
    }

    /// Mutable option picks for one model, created empty on first use.
    pub fn modelOptionsMut(self: *ComposerDefaults, a: Allocator, harness: HarnessId, model: []const u8) !*ModelOptions {
        const per = try self.modelOptionsByModel.map.getOrPut(a, @tagName(harness));
        if (!per.found_existing) per.value_ptr.* = .{};
        const entry = try per.value_ptr.map.getOrPut(a, model);
        if (!entry.found_existing) {
            entry.key_ptr.* = try a.dupe(u8, model);
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    /// The remembered level for one model, else the global one.
    pub fn reasoningFor(self: *const ComposerDefaults, harness: HarnessId, model: ?[]const u8) ?ReasoningLevel {
        if (model) |m| if (self.reasoningByModel.map.get(@tagName(harness))) |per| {
            if (per.map.get(m)) |level| return level;
        };
        return self.reasoning;
    }

    pub fn rememberReasoning(self: *ComposerDefaults, a: Allocator, harness: HarnessId, model: ?[]const u8, level: ReasoningLevel) !void {
        self.reasoning = level;
        const m = model orelse return;
        const per = try self.reasoningByModel.map.getOrPut(a, @tagName(harness));
        if (!per.found_existing) per.value_ptr.* = .{};
        const entry = try per.value_ptr.map.getOrPut(a, m);
        if (!entry.found_existing) entry.key_ptr.* = try a.dupe(u8, m);
        entry.value_ptr.* = level;
    }

    pub fn labelFor(self: *const ComposerDefaults, id: []const u8) ?[]const u8 {
        return self.modelLabels.map.get(id);
    }

    pub fn isFavorite(self: *const ComposerDefaults, harness: HarnessId, model: []const u8) bool {
        for (self.favorites) |f| if (f.harness == harness and std.mem.eql(u8, f.model, model)) return true;
        return false;
    }

    /// Star/unstar; returns whether it is starred after the toggle.
    pub fn toggleFavorite(self: *ComposerDefaults, a: Allocator, harness: HarnessId, model: []const u8) !bool {
        var list: std.ArrayList(FavoriteModel) = .empty;
        try list.appendSlice(a, self.favorites);
        for (list.items, 0..) |f, i| if (f.harness == harness and std.mem.eql(u8, f.model, model)) {
            _ = list.orderedRemove(i);
            self.favorites = list.items;
            return false;
        };
        try list.append(a, .{ .harness = harness, .model = try a.dupe(u8, model) });
        self.favorites = list.items;
        return true;
    }

    /// Merge a loaded catalog into the label cache; true if anything changed.
    pub fn rememberLabels(self: *ComposerDefaults, a: Allocator, models: []const protocol.Model) !bool {
        var changed = false;
        for (models) |m| {
            if (self.modelLabels.map.get(m.id)) |l| if (std.mem.eql(u8, l, m.label)) continue;
            try self.modelLabels.map.put(a, try a.dupe(u8, m.id), try a.dupe(u8, m.label));
            changed = true;
        }
        return changed;
    }
};

pub const Loaded = struct {
    arena: *std.heap.ArenaAllocator,
    value: ComposerDefaults,

    pub fn allocator(self: Loaded) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: Loaded) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

pub fn load(gpa: Allocator, io: Io, data_dir: []const u8) Allocator.Error!Loaded {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var out: Loaded = .{ .arena = arena, .value = .{} };
    const p = try std.fs.path.join(gpa, &.{ data_dir, file_name });
    defer gpa.free(p);
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 20)) catch return out;
    defer gpa.free(text);
    out.value = json.parseFromSliceLeaky(ComposerDefaults, arena.allocator(), text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        std.log.scoped(.zeron_composer_defaults).warn("composer-defaults corrupt; using defaults ({t})", .{err});
        break :blk .{};
    };
    return out;
}

/// Write atomically (temp file + rename).
pub fn save(defaults: *const ComposerDefaults, gpa: Allocator, io: Io, data_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, data_dir);
    const final = try std.fs.path.join(gpa, &.{ data_dir, file_name });
    defer gpa.free(final);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ final, std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(tmp);
    const text = try json.Stringify.valueAlloc(gpa, defaults.*, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
    defer gpa.free(text);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
}

test "composer defaults round trip" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(dir);
    var d = try load(t.allocator, io, dir);
    defer d.deinit();
    const a = d.allocator();
    try d.value.rememberModel(a, .@"claude-code", "claude-fable-5", "Fable 5");
    try d.value.rememberReasoning(a, .@"claude-code", "claude-fable-5", .xhigh);
    const opts = try d.value.modelOptionsMut(a, .@"claude-code", "claude-fable-5");
    try opts.map.put(a, "contextWindow", .{ .string = "1m" });
    try t.expect(try d.value.toggleFavorite(a, .codex, "gpt-5.2"));
    d.value.noProject = true;
    try save(&d.value, t.allocator, io, dir);

    var back = try load(t.allocator, io, dir);
    defer back.deinit();
    try t.expectEqual(HarnessId.@"claude-code", back.value.harness.?);
    try t.expectEqualStrings("Fable 5", back.value.modelFor(.@"claude-code").?.label);
    try t.expectEqual(ReasoningLevel.xhigh, back.value.reasoningFor(.@"claude-code", "claude-fable-5").?);
    try t.expectEqual(ReasoningLevel.xhigh, back.value.reasoningFor(.codex, null).?);
    try t.expectEqualStrings("1m", back.value.modelOptionsFor(.@"claude-code", "claude-fable-5").?.map.get("contextWindow").?.string);
    try t.expect(back.value.isFavorite(.codex, "gpt-5.2"));
    try t.expect(back.value.noProject);
}
