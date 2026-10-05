//! `ComposerStore` — the zpui global that owns the composer's two
//! device-local preference files:
//!
//! - `composer-defaults.json` (`composer_defaults.zig`, the Rust app's
//!   sticky "remember my last picks" file, same name and JSON shape): the
//!   last harness, the last model per harness, reasoning per model and the
//!   label cache. The model picker writes it on every new-thread pick
//!   (Rust `Pickers::save_defaults`), synchronously and atomically.
//! - `new-thread-defaults.json` (Zig client only): the explicit default
//!   agent and model picked in Settings → General. Null fields mean
//!   "Last used" (the Rust behaviour).
//!
//! Why the explicit defaults get their own file: the Rust app parses
//! `ui-settings.json` and `composer-defaults.json` into typed structs, so it
//! ignores unknown keys on load but drops them the next time it saves
//! either file (sidebar drags, open tabs, any composer pick). A sidecar
//! file that Rust never opens can't be dropped or rejected.
//!
//! ```zig
//! composer_store.init(app, io, data_dir);              // boot (beside settings_store.init)
//! const sticky = composer_store.sticky(app);            // ?*const ComposerDefaults
//! const pref = composer_store.preferred(app);           // ?*const NewThreadDefaults
//! composer_store.rememberModel(app, .codex, "gpt-5", "GPT-5");
//! composer_store.setPreferred(app, .{ .harness = .codex });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const zpui = @import("zpui");
const protocol = @import("zeron_engine").protocol;
const composer_defaults = @import("composer_defaults.zig");

const App = zpui.App;
const HarnessId = protocol.HarnessId;
const ReasoningLevel = protocol.ReasoningLevel;
const ComposerDefaults = composer_defaults.ComposerDefaults;
const log = std.log.scoped(.zeron_composer_defaults);

pub const preferred_file_name = "new-thread-defaults.json";

/// A model picked as the default: id plus label, so the chip names it
/// before the harness's model list loads.
pub const PreferredModel = struct { id: []const u8, label: []const u8 };

/// Explicit defaults for new threads. `null` = "Last used".
pub const NewThreadDefaults = struct {
    /// The default agent (harness).
    harness: ?HarnessId = null,
    /// The default model of `harness`; ignored without `harness` and for
    /// any other harness.
    model: ?PreferredModel = null,

    /// The default model for harness `h`, if one is set for it.
    pub fn modelFor(self: *const NewThreadDefaults, h: HarnessId) ?PreferredModel {
        const own = self.harness orelse return null;
        if (own != h) return null;
        return self.model;
    }
};

pub const PreferredLoaded = struct {
    arena: *std.heap.ArenaAllocator,
    value: NewThreadDefaults,

    pub fn deinit(self: PreferredLoaded) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

fn emptyPreferred(gpa: Allocator) Allocator.Error!PreferredLoaded {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return .{ .arena = arena, .value = .{} };
}

/// Parse `new-thread-defaults.json` text; defaults when corrupt. Unknown
/// keys and unknown harness ids (a newer build) read as "Last used".
pub fn parsePreferred(gpa: Allocator, text: []const u8) Allocator.Error!PreferredLoaded {
    var out = try emptyPreferred(gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const root = json.parseFromSliceLeaky(json.Value, a, text, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.warn("{s} corrupt; using defaults ({t})", .{ preferred_file_name, err });
        return out;
    };
    if (root != .object) return out;
    const h = root.object.get("harness") orelse return out;
    if (h != .string) return out;
    out.value.harness = std.meta.stringToEnum(HarnessId, h.string) orelse return out;
    if (root.object.get("model")) |m| if (m == .object) {
        const id = m.object.get("id") orelse return out;
        if (id != .string or id.string.len == 0) return out;
        const label = if (m.object.get("label")) |l| (if (l == .string) l.string else id.string) else id.string;
        out.value.model = .{ .id = id.string, .label = label };
    };
    return out;
}

pub fn loadPreferred(gpa: Allocator, io: Io, data_dir: []const u8) Allocator.Error!PreferredLoaded {
    const p = try std.fs.path.join(gpa, &.{ data_dir, preferred_file_name });
    defer gpa.free(p);
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch return emptyPreferred(gpa);
    defer gpa.free(text);
    return parsePreferred(gpa, text);
}

/// Write atomically (temp file + rename).
pub fn savePreferred(value: *const NewThreadDefaults, gpa: Allocator, io: Io, data_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, data_dir);
    const final = try std.fs.path.join(gpa, &.{ data_dir, preferred_file_name });
    defer gpa.free(final);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ final, std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(tmp);
    const text = try json.Stringify.valueAlloc(gpa, value.*, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
    defer gpa.free(text);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
}

// ---------------------------------------------------------------------------
// The global
// ---------------------------------------------------------------------------

pub const ComposerStore = struct {
    gpa: Allocator,
    io: ?Io,
    data_dir: []u8,
    /// False for an in-memory store (fixture mode, tests): nothing is written.
    persist: bool,
    sticky: composer_defaults.Loaded,
    preferred: PreferredLoaded,

    pub fn deinit(self: *ComposerStore, _: *App) void {
        self.sticky.deinit();
        self.preferred.deinit();
        self.gpa.free(self.data_dir);
    }

    fn saveSticky(self: *ComposerStore) void {
        if (!self.persist) return;
        const io = self.io orelse return;
        composer_defaults.save(&self.sticky.value, self.gpa, io, self.data_dir) catch |err|
            log.warn("composer-defaults save failed: {t}", .{err});
    }

    fn savePreferredFile(self: *ComposerStore) void {
        if (!self.persist) return;
        const io = self.io orelse return;
        savePreferred(&self.preferred.value, self.gpa, io, self.data_dir) catch |err|
            log.warn("{s} save failed: {t}", .{ preferred_file_name, err });
    }
};

/// Load both files from `data_dir` and install the global.
pub fn init(app: *App, io: Io, data_dir: []const u8) !void {
    const sticky_loaded = try composer_defaults.load(app.gpa, io, data_dir);
    errdefer sticky_loaded.deinit();
    const pref = try loadPreferred(app.gpa, io, data_dir);
    errdefer pref.deinit();
    const dir = try app.gpa.dupe(u8, data_dir);
    errdefer app.gpa.free(dir);
    try app.setGlobal(ComposerStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = true, .sticky = sticky_loaded, .preferred = pref });
}

/// An empty in-memory store (never written).
pub fn initMemory(app: *App) !void {
    const arena = try app.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(app.gpa);
    const sticky_loaded: composer_defaults.Loaded = .{ .arena = arena, .value = .{} };
    errdefer sticky_loaded.deinit();
    const pref = try emptyPreferred(app.gpa);
    errdefer pref.deinit();
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(ComposerStore{ .gpa = app.gpa, .io = null, .data_dir = dir, .persist = false, .sticky = sticky_loaded, .preferred = pref });
}

/// Install an in-memory store unless one exists.
pub fn ensure(app: *App) void {
    if (app.hasGlobal(ComposerStore)) return;
    initMemory(app) catch {};
}

/// The sticky last-used picks (null when no store is installed).
pub fn sticky(app: *App) ?*const ComposerDefaults {
    const s = app.tryGlobal(ComposerStore) orelse return null;
    return &s.sticky.value;
}

/// The explicit new-thread defaults (null when no store is installed).
pub fn preferred(app: *App) ?*const NewThreadDefaults {
    const s = app.tryGlobal(ComposerStore) orelse return null;
    return &s.preferred.value;
}

/// Mutate the sticky picks with `mutate(ctx, *ComposerDefaults, arena) !bool`
/// (true = changed) and save when it changed. Observers are notified.
pub fn updateSticky(app: *App, ctx: anytype, comptime mutate: anytype) void {
    if (!app.hasGlobal(ComposerStore)) return;
    const C = @TypeOf(ctx);
    const Run = struct {
        fn run(c: C, s: *ComposerStore, _: *App) void {
            const changed = mutate(c, &s.sticky.value, s.sticky.allocator()) catch |err| {
                log.warn("composer-defaults update failed: {t}", .{err});
                return;
            };
            if (changed) s.saveSticky();
        }
    };
    app.updateGlobal(ComposerStore, ctx, Run.run);
}

/// `remember_model`: the new-thread pick of `id` for `harness`.
pub fn rememberModel(app: *App, harness: HarnessId, id: []const u8, label: []const u8) void {
    const C = struct { HarnessId, []const u8, []const u8 };
    const M = struct {
        fn f(c: C, d: *ComposerDefaults, a: Allocator) !bool {
            try d.rememberModel(a, c[0], c[1], c[2]);
            return true;
        }
    };
    updateSticky(app, C{ harness, id, label }, M.f);
}

/// `pick_harness` on the new-thread canvas: remember the harness.
pub fn rememberHarness(app: *App, harness: HarnessId) void {
    const M = struct {
        fn f(h: HarnessId, d: *ComposerDefaults, _: Allocator) !bool {
            if (d.harness == h) return false;
            d.harness = h;
            return true;
        }
    };
    updateSticky(app, harness, M.f);
}

/// `pick_reasoning` on the new-thread canvas.
pub fn rememberReasoning(app: *App, harness: ?HarnessId, model_id: ?[]const u8, level: ReasoningLevel) void {
    const C = struct { ?HarnessId, ?[]const u8, ReasoningLevel };
    const M = struct {
        fn f(c: C, d: *ComposerDefaults, a: Allocator) !bool {
            if (c[0]) |h| try d.rememberReasoning(a, h, c[1], c[2]) else d.reasoning = c[2];
            return true;
        }
    };
    updateSticky(app, C{ harness, model_id, level }, M.f);
}

/// Merge a loaded catalog into the label cache (saved only when it changed).
pub fn rememberLabels(app: *App, models: []const protocol.Model) void {
    const store = app.tryGlobal(ComposerStore) orelse return;
    // Most catalog notifications carry nothing new: skip the update (and
    // its observer notification) then.
    const fresh = for (models) |m| {
        if (store.sticky.value.labelFor(m.id)) |l| if (std.mem.eql(u8, l, m.label)) continue;
        break true;
    } else false;
    if (!fresh) return;
    const M = struct {
        fn f(ms: []const protocol.Model, d: *ComposerDefaults, a: Allocator) !bool {
            return d.rememberLabels(a, ms);
        }
    };
    updateSticky(app, models, M.f);
}

/// Replace the explicit new-thread defaults (strings are copied) and save.
pub fn setPreferred(app: *App, value: NewThreadDefaults) void {
    ensure(app);
    const Run = struct {
        fn run(v: NewThreadDefaults, s: *ComposerStore, _: *App) void {
            if (eqlPreferred(&s.preferred.value, &v)) return;
            const a = s.preferred.arena.allocator();
            var next: NewThreadDefaults = .{ .harness = v.harness };
            if (v.harness != null) if (v.model) |m| {
                next.model = .{ .id = a.dupe(u8, m.id) catch return, .label = a.dupe(u8, m.label) catch return };
            };
            s.preferred.value = next;
            s.savePreferredFile();
        }
    };
    app.updateGlobal(ComposerStore, value, Run.run);
}

pub fn eqlPreferred(a: *const NewThreadDefaults, b: *const NewThreadDefaults) bool {
    if (a.harness != b.harness) return false;
    const am = a.model orelse return b.model == null;
    const bm = b.model orelse return false;
    return std.mem.eql(u8, am.id, bm.id) and std.mem.eql(u8, am.label, bm.label);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpPath(tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "new-thread defaults round trip through their own file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(&tmp);
    defer testing.allocator.free(dir);

    // Missing file: "Last used" for both.
    const empty = try loadPreferred(testing.allocator, io, dir);
    try testing.expect(empty.value.harness == null and empty.value.model == null);
    empty.deinit();

    const v: NewThreadDefaults = .{ .harness = .codex, .model = .{ .id = "gpt-5.2-codex", .label = "GPT-5.2 Codex" } };
    try savePreferred(&v, testing.allocator, io, dir);
    const back = try loadPreferred(testing.allocator, io, dir);
    defer back.deinit();
    try testing.expect(eqlPreferred(&v, &back.value));
    try testing.expectEqualStrings("gpt-5.2-codex", back.value.modelFor(.codex).?.id);
    try testing.expect(back.value.modelFor(.@"claude-code") == null);
}

test "new-thread defaults: corrupt, unknown harness and stray keys read as Last used" {
    const cases = [_][]const u8{
        "{nope",
        "[]",
        \\{"harness":"some-future-agent","model":{"id":"x","label":"X"}}
        ,
        \\{"harness":42}
        ,
    };
    for (cases) |text| {
        const l = try parsePreferred(testing.allocator, text);
        defer l.deinit();
        try testing.expect(l.value.harness == null and l.value.model == null);
    }
    const l = try parsePreferred(testing.allocator,
        \\{"futureKey":true,"harness":"claude-code","model":{"id":"claude-opus-5"}}
    );
    defer l.deinit();
    try testing.expectEqual(HarnessId.@"claude-code", l.value.harness.?);
    try testing.expectEqualStrings("claude-opus-5", l.value.model.?.label); // label falls back to the id
}

/// `composer-defaults.json` as the Rust app writes it
/// (apps/zeron/scripts/composer_defaults_parity.rs).
const rust_fixture = @embedFile("testdata/composer_defaults_rust.json");

/// JSON equality where a `null` member equals a missing one (serde writes
/// `None` as null; the Zig writer omits it; both read either).
fn sameJson(a: json.Value, b: json.Value) bool {
    switch (a) {
        .object => |ao| {
            if (b != .object) return false;
            const bo = b.object;
            var it = ao.iterator();
            while (it.next()) |e| {
                const other = bo.get(e.key_ptr.*) orelse json.Value.null;
                if (!sameJson(e.value_ptr.*, other)) return false;
            }
            var it2 = bo.iterator();
            while (it2.next()) |e| if (!ao.contains(e.key_ptr.*) and e.value_ptr.* != .null) return false;
            return true;
        },
        .array => |aa| {
            if (b != .array or b.array.items.len != aa.items.len) return false;
            for (aa.items, b.array.items) |x, y| if (!sameJson(x, y)) return false;
            return true;
        },
        .string => |x| return b == .string and std.mem.eql(u8, x, b.string),
        .null => return b == .null,
        .bool => |x| return b == .bool and b.bool == x,
        else => return std.meta.eql(a, b),
    }
}

test "composer-defaults.json: Rust's file loads, and the Zig rewrite is the same document" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(&tmp);
    defer testing.allocator.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, composer_defaults.file_name });
    defer testing.allocator.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rust_fixture });

    const d = try composer_defaults.load(testing.allocator, io, dir);
    defer d.deinit();
    try testing.expectEqual(HarnessId.codex, d.value.harness.?);
    try testing.expectEqualStrings("Fable 5", d.value.modelFor(.@"claude-code").?.label);
    try testing.expectEqualStrings("gpt-5.2-codex", d.value.modelFor(.codex).?.id);
    try testing.expectEqual(ReasoningLevel.xhigh, d.value.reasoningFor(.codex, "gpt-5.2-codex").?);
    try testing.expect(d.value.isFavorite(.@"claude-code", "claude-fable-5"));

    // Write it back from Zig: Rust reads the same document it wrote.
    try composer_defaults.save(&d.value, testing.allocator, io, dir);
    const text = try Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ours = try json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{});
    const theirs = try json.parseFromSliceLeaky(json.Value, arena.allocator(), rust_fixture, .{});
    try testing.expect(sameJson(ours, theirs));
}

test "ComposerStore persists picks and defaults; files stay Rust-compatible" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(&tmp);
    defer testing.allocator.free(dir);

    try Io.Dir.cwd().createDirPath(io, dir);
    const rust_path = try std.fs.path.join(testing.allocator, &.{ dir, composer_defaults.file_name });
    defer testing.allocator.free(rust_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rust_path, .data = rust_fixture });

    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try init(app, io, dir);
    try testing.expectEqual(HarnessId.codex, sticky(app).?.harness.?);
    try testing.expectEqualStrings("Fable 5", sticky(app).?.modelFor(.@"claude-code").?.label);
    try testing.expect(preferred(app).?.harness == null);

    rememberModel(app, .@"claude-code", "claude-opus-5", "Opus 5");
    rememberReasoning(app, .@"claude-code", "claude-opus-5", .max);
    setPreferred(app, .{ .harness = .codex, .model = .{ .id = "gpt-5.3-codex", .label = "GPT-5.3 Codex" } });

    // The sticky file keeps Rust's shape: no explicit-default keys leak into it.
    const text = try Io.Dir.cwd().readFileAlloc(io, rust_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"modelByHarness\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "gpt-5.3-codex") == null);

    // A fresh load (next launch) sees both.
    const s2 = try composer_defaults.load(testing.allocator, io, dir);
    defer s2.deinit();
    try testing.expectEqual(HarnessId.@"claude-code", s2.value.harness.?);
    try testing.expectEqualStrings("claude-opus-5", s2.value.modelFor(.@"claude-code").?.id);
    try testing.expectEqualStrings("gpt-5.2-codex", s2.value.modelFor(.codex).?.id);
    try testing.expectEqual(ReasoningLevel.max, s2.value.reasoningFor(.@"claude-code", "claude-opus-5").?);
    const p2 = try loadPreferred(testing.allocator, io, dir);
    defer p2.deinit();
    try testing.expectEqualStrings("GPT-5.3 Codex", p2.value.modelFor(.codex).?.label);

    // Back to "Last used".
    setPreferred(app, .{});
    const p3 = try loadPreferred(testing.allocator, io, dir);
    defer p3.deinit();
    try testing.expect(p3.value.harness == null and p3.value.model == null);
}
