//! Durable custom-theme library (port of zeron `crates/theme/src/library.rs`):
//! `{data_dir}/theme-library.json` (shared with the Rust app, serde-compatible),
//! written through a temp file + `.json.bak` so an interrupted save is
//! recoverable, and the bridge into the runtime registry (`registry.active`).
//!
//! ```zig
//! var lib = try library.load(gpa, io, data_dir, &diag);    // missing file → empty
//! const id = try lib.install(io, compilation, &.{}, .snapshot, &diag);
//! try lib.save(io, data_dir, &diag);
//! lib.installRuntime();                                     // registry.active() sees it
//! ```
//!
//! A `Library` owns every string through its arena; mutations build a new
//! arena-backed value (the previous one stays valid until `deinit`).

const std = @import("std");
const model = @import("model.zig");
const registry = @import("registry.zig");
const vscode = @import("vscode.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const Color = model.Color;
const ThemeVariant = model.ThemeVariant;
const ThemeFamily = model.ThemeFamily;
const Diagnostic = vscode.Diagnostic;
const ImportReport = vscode.ImportReport;
const ReportEntry = vscode.ReportEntry;

pub const library_file = "theme-library.json";
pub const max_library_bytes: u64 = 16 * 1024 * 1024;
pub const max_library_entries: usize = 256;
pub const max_library_variants: usize = 1024;

pub const InstallMode = enum { snapshot, link };

pub const Source = union(enum) {
    imported_snapshot: ?[]const u8,
    linked_file: []const u8,
    linked_package: []const u8,
    editable_file: []const u8,

    pub fn path(self: Source) ?[]const u8 {
        return switch (self) {
            .imported_snapshot => |p| p,
            inline else => |p| p,
        };
    }

    pub fn isLinked(self: Source) bool {
        return self != .imported_snapshot;
    }

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .imported_snapshot => "Imported",
            .linked_file => "Linked file",
            .linked_package => "Linked package",
            .editable_file => "Editable file",
        };
    }

    fn kind(self: Source) []const u8 {
        return switch (self) {
            .imported_snapshot => "importedSnapshot",
            .linked_file => "linkedFile",
            .linked_package => "linkedPackage",
            .editable_file => "editableFile",
        };
    }
};

pub const Status = union(enum) { ready, warning: []const u8 };

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    source: Source,
    family: ThemeFamily,
    /// Sorted by variant id.
    reports: []const ReportEntry,
    selected_variant_ids: []const []const u8,
    status: Status = .ready,

    pub fn report(self: *const Entry, variant_id: []const u8) ?*const ImportReport {
        for (self.reports) |*r| if (std.mem.eql(u8, r.variant_id, variant_id)) return &r.report;
        return null;
    }
};

pub const Error = error{ OutOfMemory, LibraryFailed };

fn fail(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set(fmt, args);
    return error.LibraryFailed;
}

pub const Library = struct {
    arena: *std.heap.ArenaAllocator,
    entries: []const Entry = &.{},

    pub fn init(gpa: Allocator) Allocator.Error!Library {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        return .{ .arena = arena };
    }

    pub fn deinit(self: *Library) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    fn a(self: *Library) Allocator {
        return self.arena.allocator();
    }

    pub fn entry(self: *const Library, id: []const u8) ?*const Entry {
        for (self.entries) |*e| if (std.mem.eql(u8, e.id, id)) return e;
        return null;
    }

    fn variantCount(self: *const Library) usize {
        var n: usize = 0;
        for (self.entries) |e| n += e.family.variants.len;
        return n;
    }

    fn validateCapacity(self: *const Library, diag: *Diagnostic) Error!void {
        if (self.entries.len > max_library_entries) return fail(diag, "custom theme library is limited to {d} entries", .{max_library_entries});
        if (self.variantCount() > max_library_variants) return fail(diag, "custom theme library is limited to {d} variants", .{max_library_variants});
    }

    fn ensureCapacityFor(self: *const Library, additional: usize, diag: *Diagnostic) Error!void {
        if (self.entries.len >= max_library_entries) return fail(diag, "custom theme library is limited to {d} entries", .{max_library_entries});
        if (self.variantCount() + additional > max_library_variants) return fail(diag, "custom theme library is limited to {d} variants", .{max_library_variants});
    }

    fn push(self: *Library, e: Entry) Allocator.Error!void {
        const list = try self.a().alloc(Entry, self.entries.len + 1);
        @memcpy(list[0..self.entries.len], self.entries);
        list[self.entries.len] = e;
        self.entries = list;
    }

    fn mutable(self: *Library, id: []const u8) ?*Entry {
        const list = self.a().dupe(Entry, self.entries) catch return null;
        self.entries = list;
        for (list) |*e| if (std.mem.eql(u8, e.id, id)) return e;
        return null;
    }

    /// The families the runtime registry should carry.
    pub fn families(self: *const Library, out_alloc: Allocator) Allocator.Error![]const ThemeFamily {
        const out = try out_alloc.alloc(ThemeFamily, self.entries.len);
        for (self.entries, out) |e, *f| f.* = e.family;
        return out;
    }

    /// `install_runtime`: make these families visible through `registry.active()`.
    /// The library must outlive every theme built from it.
    pub fn installRuntime(self: *Library) void {
        registry.setCustom(self.families(self.a()) catch &.{});
    }

    /// `CustomThemeLibrary::install`.
    pub fn install(self: *Library, compilation: *const vscode.SourceCompilation, selected_ids: []const []const u8, mode: InstallMode, diag: *Diagnostic) Error![]const u8 {
        const al = self.a();
        var kept: std.ArrayList(ThemeVariant) = .empty;
        for (compilation.family.variants) |v| {
            const wanted = selected_ids.len == 0 or for (selected_ids) |s| (if (std.mem.eql(u8, s, v.id)) break true) else false;
            if (wanted) try kept.append(al, try cloneVariant(al, v));
        }
        if (kept.items.len == 0) return fail(diag, "select at least one successfully compiled variant", .{});
        try self.ensureCapacityFor(kept.items.len, diag);
        const entry_id = try uniqueId(al, compilation.family.id, self.entries);
        var family: ThemeFamily = .{ .id = try al.dupe(u8, compilation.family.id), .name = try al.dupe(u8, compilation.family.name), .variants = kept.items };
        const old_ids = try al.alloc([]const u8, kept.items.len);
        for (kept.items, old_ids) |v, *o| o.* = v.id;
        if (!std.mem.eql(u8, entry_id, family.id)) try rekeyFamily(al, &family, entry_id);
        try validateFamily(al, &family, "theme validation failed: ", diag);
        var reports: std.ArrayList(ReportEntry) = .empty;
        for (old_ids, family.variants) |old, v| if (compilation.report(old)) |r| try reports.append(al, .{ .variant_id = v.id, .report = try cloneReport(al, r.*) });
        sortReports(reports.items);
        const path = try al.dupe(u8, compilation.path);
        const source: Source = switch (mode) {
            .snapshot => .{ .imported_snapshot = path },
            .link => if (compilation.source_kind == .file) .{ .linked_file = path } else .{ .linked_package = path },
        };
        try self.push(.{
            .id = entry_id,
            .name = family.name,
            .source = source,
            .family = family,
            .reports = reports.items,
            .selected_variant_ids = try variantIds(al, family),
        });
        try self.validateCapacity(diag);
        return entry_id;
    }

    /// `reload`: recompile a linked source (or re-read an editable file);
    /// the last known good family survives any failure (status → warning).
    pub fn reload(self: *Library, gpa: Allocator, io: Io, id: []const u8, diag: *Diagnostic) Error!void {
        const al = self.a();
        const e = self.mutable(id) orelse return fail(diag, "unknown custom theme `{s}`", .{id});
        const path = switch (e.source) {
            .linked_file, .linked_package => |p| p,
            .editable_file => |p| {
                const family = loadEditableFamily(gpa, al, io, p, e.id, diag) catch |err| {
                    e.status = .{ .warning = try al.dupe(u8, diag.message()) };
                    return err;
                };
                e.selected_variant_ids = try variantIds(al, family);
                e.name = family.name;
                e.family = family;
                e.reports = &.{};
                e.status = .ready;
                return;
            },
            .imported_snapshot => return fail(diag, "imported snapshots cannot reload", .{}),
        };
        var sub: Diagnostic = .{};
        var comp = compile(gpa, io, path, e.id, e.name, &sub) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            e.status = .{ .warning = try al.dupe(u8, sub.message()) };
            return fail(diag, "{s}", .{sub.message()});
        };
        defer comp.deinit();
        var failed: std.ArrayList(u8) = .empty;
        for (comp.value.failures) |f| if (contains(e.selected_variant_ids, f.id)) {
            if (failed.items.len > 0) try failed.appendSlice(al, "; ");
            try failed.print(al, "{s}: {s}", .{ f.name, f.message });
        };
        if (failed.items.len > 0) {
            e.status = .{ .warning = failed.items };
            return fail(diag, "{s}", .{failed.items});
        }
        var kept: std.ArrayList(ThemeVariant) = .empty;
        for (comp.value.family.variants) |v| if (contains(e.selected_variant_ids, v.id)) try kept.append(al, try cloneVariant(al, v));
        if (kept.items.len == 0) {
            const msg = "the linked source no longer contains any selected variants";
            e.status = .{ .warning = msg };
            return fail(diag, msg, .{});
        }
        const family: ThemeFamily = .{ .id = try al.dupe(u8, comp.value.family.id), .name = try al.dupe(u8, comp.value.family.name), .variants = kept.items };
        validateFamily(al, &family, "theme validation failed: ", diag) catch |err| {
            e.status = .{ .warning = try al.dupe(u8, diag.message()) };
            return err;
        };
        var reports: std.ArrayList(ReportEntry) = .empty;
        for (comp.value.reports) |r| if (contains(e.selected_variant_ids, r.variant_id)) try reports.append(al, .{ .variant_id = try al.dupe(u8, r.variant_id), .report = try cloneReport(al, r.report) });
        e.family = family;
        e.reports = reports.items;
        e.status = .ready;
    }

    /// `unlink`: keep the compiled family as a snapshot.
    pub fn unlink(self: *Library, id: []const u8, diag: *Diagnostic) Error!void {
        const e = self.mutable(id) orelse return fail(diag, "unknown custom theme `{s}`", .{id});
        e.source = .{ .imported_snapshot = e.source.path() };
        e.status = .ready;
    }

    /// `duplicate_as_editable`: a native, user-editable family file in `{data_dir}/custom-themes`.
    pub fn duplicateAsEditable(self: *Library, io: Io, id: []const u8, data_dir: []const u8, diag: *Diagnostic) Error![]const u8 {
        const al = self.a();
        const original = (self.entry(id) orelse return fail(diag, "unknown custom theme `{s}`", .{id})).*;
        try self.ensureCapacityFor(original.family.variants.len, diag);
        const new_id = try uniqueId(al, try std.fmt.allocPrint(al, "{s}-copy", .{original.id}), self.entries);
        var family: ThemeFamily = .{ .id = original.family.id, .name = try std.fmt.allocPrint(al, "{s} Copy", .{original.family.name}), .variants = try al.dupe(ThemeVariant, original.family.variants) };
        try rekeyFamily(al, &family, new_id);
        const dir = try std.fs.path.join(al, &.{ data_dir, "custom-themes" });
        Io.Dir.cwd().createDirPath(io, dir) catch return fail(diag, "could not create {s}", .{dir});
        const path = try std.fs.path.join(al, &.{ dir, try std.fmt.allocPrint(al, "{s}.zeron-theme.json", .{new_id}) });
        var aw: Io.Writer.Allocating = .init(al);
        try writeFamilyPretty(al, &aw.writer, family);
        try replaceFileRecoverably(io, path, aw.written(), diag);
        try self.push(.{
            .id = new_id,
            .name = family.name,
            .source = .{ .editable_file = path },
            .family = family,
            .reports = &.{},
            .selected_variant_ids = try variantIds(al, family),
        });
        return new_id;
    }

    /// `remove`; returns whether an entry was dropped.
    pub fn remove(self: *Library, id: []const u8) bool {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries) |e| if (!std.mem.eql(u8, e.id, id)) out.append(self.a(), e) catch return false;
        const removed = out.items.len != self.entries.len;
        self.entries = out.items;
        return removed;
    }

    /// `save`: pretty JSON through a temp file and a recoverable backup.
    pub fn save(self: *const Library, io: Io, data_dir: []const u8, diag: *Diagnostic) Error!void {
        try self.validateCapacity(diag);
        Io.Dir.cwd().createDirPath(io, data_dir) catch return fail(diag, "could not create {s}", .{data_dir});
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const path = try std.fs.path.join(sa, &.{ data_dir, library_file });
        var aw: Io.Writer.Allocating = .init(sa);
        try writeLibrary(sa, &aw.writer, self);
        if (aw.written().len > max_library_bytes) return fail(diag, "custom theme library exceeds the {d}-byte limit", .{max_library_bytes});
        try replaceFileRecoverably(io, path, aw.written(), diag);
    }
};

/// `CustomThemeLibrary::compile` (local source, user-supplied license).
pub fn compile(gpa: Allocator, io: Io, path: []const u8, family_id: []const u8, family_name: []const u8, diag: *Diagnostic) vscode.Error!vscode.Owned(vscode.SourceCompilation) {
    return vscode.compileSource(gpa, io, path, .{ .family_id = family_id, .family_name = family_name, .source_url = path, .revision = "local", .license = "User supplied" }, diag);
}

// ---- load ----------------------------------------------------------------------------------

/// `CustomThemeLibrary::load`: the primary file, else its backup; missing → empty.
pub fn load(gpa: Allocator, io: Io, data_dir: []const u8, diag: *Diagnostic) Error!Library {
    var lib = try Library.init(gpa);
    errdefer lib.deinit();
    const al = lib.a();
    const path = try std.fs.path.join(al, &.{ data_dir, library_file });
    const backup = try backupPath(al, path);
    const exists = if (Io.Dir.cwd().statFile(io, path, .{})) |_| true else |_| false;
    const load_path = if (exists) path else backup;
    const st = Io.Dir.cwd().statFile(io, load_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return lib,
        else => return fail(diag, "could not read {s}", .{path}),
    };
    if (st.size > max_library_bytes) return fail(diag, "could not read {s}", .{path});
    const text = Io.Dir.cwd().readFileAlloc(io, load_path, al, .limited(max_library_bytes + 1)) catch return fail(diag, "could not read {s}", .{path});
    const value = json.parseFromSliceLeaky(json.Value, al, text, .{ .allocate = .alloc_always, .duplicate_field_behavior = .use_last }) catch return fail(diag, "could not parse {s}", .{load_path});
    lib.entries = parseLibrary(al, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diag, "could not parse {s}", .{load_path}),
    };
    try lib.validateCapacity(diag);
    return lib;
}

fn str(v: ?json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn need(v: ?json.Value) error{Malformed}![]const u8 {
    return str(v) orelse error.Malformed;
}

fn objOf(v: ?json.Value) error{Malformed}!json.ObjectMap {
    return switch (v orelse return error.Malformed) {
        .object => |o| o,
        else => error.Malformed,
    };
}

fn arrOf(v: ?json.Value) error{Malformed}![]const json.Value {
    return switch (v orelse return error.Malformed) {
        .array => |x| x.items,
        else => error.Malformed,
    };
}

fn color(v: ?json.Value) error{Malformed}!Color {
    return Color.parse(try need(v)) catch error.Malformed;
}

const ParseError = error{ OutOfMemory, Malformed };

fn parseLibrary(al: Allocator, v: json.Value) ParseError![]const Entry {
    const root = try objOf(v);
    const list = if (root.get("entries")) |e| try arrOf(e) else return &.{};
    const out = try al.alloc(Entry, list.len);
    for (list, out) |item, *e| e.* = try parseEntry(al, item);
    return out;
}

fn parseEntry(al: Allocator, v: json.Value) ParseError!Entry {
    const o = try objOf(v);
    const src = try objOf(o.get("source"));
    const kind = try need(src.get("kind"));
    const eq = std.mem.eql;
    const source: Source = if (eq(u8, kind, "importedSnapshot"))
        .{ .imported_snapshot = str(src.get("imported_from")) }
    else if (eq(u8, kind, "linkedFile"))
        .{ .linked_file = try need(src.get("path")) }
    else if (eq(u8, kind, "linkedPackage"))
        .{ .linked_package = try need(src.get("path")) }
    else if (eq(u8, kind, "editableFile"))
        .{ .editable_file = try need(src.get("path")) }
    else
        return error.Malformed;
    var reports: std.ArrayList(ReportEntry) = .empty;
    if (o.get("reports")) |r| {
        var it = (try objOf(r)).iterator();
        while (it.next()) |kv| try reports.append(al, .{ .variant_id = kv.key_ptr.*, .report = try parseReport(al, kv.value_ptr.*) });
    }
    sortReports(reports.items);
    const ids_v = try arrOf(o.get("selectedVariantIds"));
    const ids = try al.alloc([]const u8, ids_v.len);
    for (ids_v, ids) |x, *d| d.* = try need(x);
    const status: Status = if (o.get("status")) |s| blk: {
        const so = try objOf(s);
        break :blk if (eq(u8, try need(so.get("kind")), "warning")) .{ .warning = try need(so.get("message")) } else .ready;
    } else .ready;
    return .{
        .id = try need(o.get("id")),
        .name = try need(o.get("name")),
        .source = source,
        .family = try parseFamily(al, o.get("family") orelse return error.Malformed),
        .reports = reports.items,
        .selected_variant_ids = ids,
        .status = status,
    };
}

pub fn parseFamily(al: Allocator, v: json.Value) ParseError!ThemeFamily {
    const o = try objOf(v);
    const vs = try arrOf(o.get("variants"));
    const variants = try al.alloc(ThemeVariant, vs.len);
    for (vs, variants) |x, *d| d.* = try parseVariant(x);
    return .{ .id = try need(o.get("id")), .name = try need(o.get("name")), .variants = variants };
}

/// A `ThemeVariant` from zeron's serde JSON (strings borrowed from `v`).
pub fn parseVariant(v: json.Value) ParseError!ThemeVariant {
    const o = try objOf(v);
    const eq = std.mem.eql;
    const appearance: model.Appearance = if (eq(u8, try need(o.get("appearance")), "light")) .light else .dark;
    const treatment_s = str(o.get("recommendedSurfaceTreatment")) orelse str(o.get("surfaceTreatment")) orelse return error.Malformed;
    const treatment: model.SurfaceTreatment = if (eq(u8, treatment_s, "frosted")) .frosted else .opaque_;
    const c = try objOf(o.get("colors"));
    var colors: model.ThemeColors = undefined;
    inline for (comptime std.meta.fieldNames(model.ThemeColors)) |name| {
        @field(colors, name) = try color(c.get(comptime camel(name)));
    }
    const ac = try objOf(o.get("accent"));
    var accent: model.AccentRoles = undefined;
    inline for (.{ "primary", "strong", "wash", "on", "selection", "caret", "activity" }) |name| @field(accent, name) = try color(ac.get(name));
    const glyph = try arrOf(ac.get("glyph"));
    if (glyph.len != 3) return error.Malformed;
    for (glyph, &accent.glyph) |g, *d| d.* = try color(g);
    var syntax: model.Syntax = .initFill(null);
    if (o.get("syntax")) |syn| {
        var it = (try objOf(syn)).iterator();
        while (it.next()) |kv| if (model.SyntaxKey.fromWireName(kv.key_ptr.*)) |k| syntax.set(k, try color(kv.value_ptr.*));
    }
    const t = try objOf(o.get("terminal"));
    const ansi_v = try arrOf(t.get("ansi"));
    if (ansi_v.len != 16) return error.Malformed;
    var ansi: [16]Color = undefined;
    for (ansi_v, &ansi) |x, *d| d.* = try color(x);
    const s = try objOf(o.get("source"));
    return .{
        .id = try need(o.get("id")),
        .family_id = try need(o.get("familyId")),
        .name = try need(o.get("name")),
        .appearance = appearance,
        .recommended_surface_treatment = treatment,
        .colors = colors,
        .accent = accent,
        .syntax = syntax,
        .terminal = .{ .background = try color(t.get("background")), .foreground = try color(t.get("foreground")), .selection = try color(t.get("selection")), .ansi = ansi },
        .source = .{ .format = try need(s.get("format")), .url = try need(s.get("url")), .revision = try need(s.get("revision")), .license = try need(s.get("license")), .asset_hash = str(s.get("assetHash")) orelse "" },
    };
}

fn camel(comptime snake: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var upper = false;
    inline for (snake) |ch| {
        if (ch == '_') {
            upper = true;
        } else {
            out = out ++ &[_]u8{if (upper) std.ascii.toUpper(ch) else ch};
            upper = false;
        }
    }
    return out;
}

fn strings(al: Allocator, v: ?json.Value) ParseError![]const []const u8 {
    const list = if (v) |x| try arrOf(x) else return &.{};
    const out = try al.alloc([]const u8, list.len);
    for (list, out) |x, *d| d.* = try need(x);
    return out;
}

fn parseReport(al: Allocator, v: json.Value) ParseError!ImportReport {
    const o = try objOf(v);
    var mappings: std.ArrayList(vscode.ImportMapping) = .empty;
    if (o.get("mappings")) |m| for (try arrOf(m)) |x| {
        const mo = try objOf(x);
        try mappings.append(al, .{ .zeronRole = try need(mo.get("zeronRole")), .vscodeKey = try need(mo.get("vscodeKey")), .value = try need(mo.get("value")) });
    };
    var adjustments: std.ArrayList(vscode.ImportAdjustment) = .empty;
    if (o.get("adjustments")) |m| for (try arrOf(m)) |x| {
        const mo = try objOf(x);
        try adjustments.append(al, .{ .zeronRole = try need(mo.get("zeronRole")), .original = try need(mo.get("original")), .resolved = try need(mo.get("resolved")), .reason = try need(mo.get("reason")) });
    };
    var accents: std.ArrayList(vscode.AccentCandidate) = .empty;
    if (o.get("accentCandidates")) |m| for (try arrOf(m)) |x| {
        const mo = try objOf(x);
        try accents.append(al, .{ .vscodeKey = try need(mo.get("vscodeKey")), .value = try need(mo.get("value")) });
    };
    var validation: std.ArrayList(vscode.ReportIssue) = .empty;
    if (o.get("validation")) |m| for (try arrOf(m)) |x| {
        const mo = try objOf(x);
        const cat = str(mo.get("category")) orelse "contrast";
        try validation.append(al, .{
            .variant_id = try need(mo.get("variant_id")),
            .category = if (std.mem.eql(u8, cat, "structural")) .structural else .contrast,
            .severity = if (std.mem.eql(u8, try need(mo.get("severity")), "warning")) .warning else .err,
            .message = try need(mo.get("message")),
        });
    };
    return .{
        .sourceFiles = try strings(al, o.get("sourceFiles")),
        .sourceHash = str(o.get("sourceHash")) orelse "",
        .mappings = mappings.items,
        .fallbacks = try strings(al, o.get("fallbacks")),
        .dropped = try strings(al, o.get("dropped")),
        .warnings = try strings(al, o.get("warnings")),
        .adjustments = adjustments.items,
        .accentCandidates = accents.items,
        .validation = validation.items,
    };
}

// ---- write ---------------------------------------------------------------------------------

fn variantValue(al: Allocator, v: ThemeVariant) Allocator.Error!json.Value {
    var aw: Io.Writer.Allocating = .init(al);
    v.writeJson(&aw.writer) catch return error.OutOfMemory;
    return json.parseFromSliceLeaky(json.Value, al, aw.written(), .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // writeJson always emits valid JSON
    };
}

fn sv(s: []const u8) json.Value {
    return .{ .string = s };
}

fn strArray(al: Allocator, list: []const []const u8) Allocator.Error!json.Value {
    var arr: json.Array = .init(al);
    for (list) |s| try arr.append(sv(s));
    return .{ .array = arr };
}

fn familyValue(al: Allocator, f: ThemeFamily) Allocator.Error!json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(al, "id", sv(f.id));
    try o.put(al, "name", sv(f.name));
    var arr: json.Array = .init(al);
    for (f.variants) |v| try arr.append(try variantValue(al, v));
    try o.put(al, "variants", .{ .array = arr });
    return .{ .object = o };
}

fn reportValue(al: Allocator, r: ImportReport) Allocator.Error!json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(al, "sourceFiles", try strArray(al, r.sourceFiles));
    try o.put(al, "sourceHash", sv(r.sourceHash));
    var m: json.Array = .init(al);
    for (r.mappings) |x| {
        var mo: json.ObjectMap = .empty;
        try mo.put(al, "zeronRole", sv(x.zeronRole));
        try mo.put(al, "vscodeKey", sv(x.vscodeKey));
        try mo.put(al, "value", sv(x.value));
        try m.append(.{ .object = mo });
    }
    try o.put(al, "mappings", .{ .array = m });
    try o.put(al, "fallbacks", try strArray(al, r.fallbacks));
    try o.put(al, "dropped", try strArray(al, r.dropped));
    try o.put(al, "warnings", try strArray(al, r.warnings));
    var adj: json.Array = .init(al);
    for (r.adjustments) |x| {
        var mo: json.ObjectMap = .empty;
        try mo.put(al, "zeronRole", sv(x.zeronRole));
        try mo.put(al, "original", sv(x.original));
        try mo.put(al, "resolved", sv(x.resolved));
        try mo.put(al, "reason", sv(x.reason));
        try adj.append(.{ .object = mo });
    }
    try o.put(al, "adjustments", .{ .array = adj });
    var acc: json.Array = .init(al);
    for (r.accentCandidates) |x| {
        var mo: json.ObjectMap = .empty;
        try mo.put(al, "vscodeKey", sv(x.vscodeKey));
        try mo.put(al, "value", sv(x.value));
        try acc.append(.{ .object = mo });
    }
    try o.put(al, "accentCandidates", .{ .array = acc });
    var val: json.Array = .init(al);
    for (r.validation) |x| {
        var mo: json.ObjectMap = .empty;
        try mo.put(al, "variant_id", sv(x.variant_id));
        try mo.put(al, "category", sv(@tagName(x.category)));
        try mo.put(al, "severity", sv(if (x.severity == .warning) "warning" else "error"));
        try mo.put(al, "message", sv(x.message));
        try val.append(.{ .object = mo });
    }
    try o.put(al, "validation", .{ .array = val });
    return .{ .object = o };
}

fn entryValue(al: Allocator, e: Entry) Allocator.Error!json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(al, "id", sv(e.id));
    try o.put(al, "name", sv(e.name));
    var src: json.ObjectMap = .empty;
    try src.put(al, "kind", sv(e.source.kind()));
    switch (e.source) {
        .imported_snapshot => |p| try src.put(al, "imported_from", if (p) |x| sv(x) else .null),
        inline else => |p| try src.put(al, "path", sv(p)),
    }
    try o.put(al, "source", .{ .object = src });
    try o.put(al, "family", try familyValue(al, e.family));
    var reports: json.ObjectMap = .empty;
    for (e.reports) |r| try reports.put(al, r.variant_id, try reportValue(al, r.report));
    try o.put(al, "reports", .{ .object = reports });
    try o.put(al, "selectedVariantIds", try strArray(al, e.selected_variant_ids));
    var st: json.ObjectMap = .empty;
    switch (e.status) {
        .ready => try st.put(al, "kind", sv("ready")),
        .warning => |msg| {
            try st.put(al, "kind", sv("warning"));
            try st.put(al, "message", sv(msg));
        },
    }
    try o.put(al, "status", .{ .object = st });
    return .{ .object = o };
}

fn writeLibrary(al: Allocator, w: *Io.Writer, lib: *const Library) Allocator.Error!void {
    var root: json.ObjectMap = .empty;
    var arr: json.Array = .init(al);
    for (lib.entries) |e| try arr.append(try entryValue(al, e));
    try root.put(al, "entries", .{ .array = arr });
    json.Stringify.value(json.Value{ .object = root }, .{ .whitespace = .indent_2 }, w) catch return error.OutOfMemory;
}

fn writeFamilyPretty(al: Allocator, w: *Io.Writer, f: ThemeFamily) Allocator.Error!void {
    json.Stringify.value(try familyValue(al, f), .{ .whitespace = .indent_2 }, w) catch return error.OutOfMemory;
}

// ---- helpers ---------------------------------------------------------------------------------

fn backupPath(al: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const ext = std.fs.path.extension(path);
    return std.fmt.allocPrint(al, "{s}.json.bak", .{path[0 .. path.len - ext.len]});
}

/// Temp file → (primary → backup) → (temp → primary); the backup restores a failed swap.
fn replaceFileRecoverably(io: Io, path: []const u8, contents: []const u8, diag: *Diagnostic) Error!void {
    var buf: [4096]u8 = undefined;
    var bbuf: [4096]u8 = undefined;
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    const tmp = std.fmt.bufPrint(&buf, "{s}.json.tmp", .{stem}) catch return fail(diag, "could not create {s}", .{path});
    const backup = std.fmt.bufPrint(&bbuf, "{s}.json.bak", .{stem}) catch return fail(diag, "could not create {s}", .{path});
    const cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = tmp, .data = contents }) catch return fail(diag, "could not write {s}", .{tmp});
    const exists = if (cwd.statFile(io, path, .{})) |_| true else |_| false;
    if (!exists) {
        Io.Dir.rename(cwd, tmp, cwd, path, io) catch return fail(diag, "could not install {s}", .{path});
        return;
    }
    cwd.deleteFile(io, backup) catch {};
    Io.Dir.rename(cwd, path, cwd, backup, io) catch return fail(diag, "could not back up {s}", .{path});
    Io.Dir.rename(cwd, tmp, cwd, path, io) catch {
        Io.Dir.rename(cwd, backup, cwd, path, io) catch {};
        return fail(diag, "could not replace {s}", .{path});
    };
    cwd.deleteFile(io, backup) catch {};
}

fn loadEditableFamily(gpa: Allocator, al: Allocator, io: Io, path: []const u8, expected_id: []const u8, diag: *Diagnostic) Error!ThemeFamily {
    _ = gpa;
    const text = Io.Dir.cwd().readFileAlloc(io, path, al, .limited(max_library_bytes + 1)) catch return fail(diag, "could not read editable theme {s}", .{path});
    const value = json.parseFromSliceLeaky(json.Value, al, text, .{ .allocate = .alloc_always }) catch return fail(diag, "could not parse editable theme {s}", .{path});
    const family = parseFamily(al, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diag, "could not parse editable theme {s}", .{path}),
    };
    if (!std.mem.eql(u8, family.id, expected_id)) return fail(diag, "editable theme family id must remain `{s}` (found `{s}`)", .{ expected_id, family.id });
    try validateFamily(al, &family, "editable theme validation failed: ", diag);
    return family;
}

fn validateFamily(al: Allocator, family: *const ThemeFamily, comptime prefix: []const u8, diag: *Diagnostic) Error!void {
    const reg: model.Registry = .{ .families = &.{family.*} };
    var issues = try reg.validate(al);
    var msg: std.ArrayList(u8) = .empty;
    for (issues.items) |iss| if (iss.isBlocking()) {
        if (msg.items.len > 0) try msg.appendSlice(al, "; ");
        try msg.print(al, "{s}: {s}", .{ iss.variant_id, iss.message });
    };
    issues.deinit(al);
    if (msg.items.len > 0) return fail(diag, prefix ++ "{s}", .{msg.items});
}

fn uniqueId(al: Allocator, base: []const u8, existing: []const Entry) Allocator.Error![]const u8 {
    const taken = struct {
        fn f(list: []const Entry, id: []const u8) bool {
            for (list) |e| if (std.mem.eql(u8, e.id, id)) return true;
            return false;
        }
    }.f;
    if (!taken(existing, base)) return al.dupe(u8, base);
    var n: usize = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(al, "{s}-{d}", .{ base, n });
        if (!taken(existing, candidate)) return candidate;
    }
}

fn rekeyFamily(al: Allocator, family: *ThemeFamily, new_id: []const u8) Allocator.Error!void {
    const old_id = family.id;
    family.id = new_id;
    const variants = try al.dupe(ThemeVariant, family.variants);
    for (variants) |*v| {
        v.family_id = new_id;
        v.id = if (std.mem.startsWith(u8, v.id, old_id))
            try std.fmt.allocPrint(al, "{s}{s}", .{ new_id, v.id[old_id.len..] })
        else
            try std.fmt.allocPrint(al, "{s}-{s}", .{ new_id, v.id });
    }
    family.variants = variants;
}

fn variantIds(al: Allocator, family: ThemeFamily) Allocator.Error![]const []const u8 {
    const out = try al.alloc([]const u8, family.variants.len);
    for (family.variants, out) |v, *o| o.* = v.id;
    return out;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn sortReports(list: []ReportEntry) void {
    std.mem.sort(ReportEntry, list, {}, struct {
        fn lt(_: void, x: ReportEntry, y: ReportEntry) bool {
            return std.mem.lessThan(u8, x.variant_id, y.variant_id);
        }
    }.lt);
}

/// Deep-copy a variant's strings into `al`.
fn cloneVariant(al: Allocator, v: ThemeVariant) Allocator.Error!ThemeVariant {
    var out = v;
    out.id = try al.dupe(u8, v.id);
    out.family_id = try al.dupe(u8, v.family_id);
    out.name = try al.dupe(u8, v.name);
    out.source = .{
        .format = try al.dupe(u8, v.source.format),
        .url = try al.dupe(u8, v.source.url),
        .revision = try al.dupe(u8, v.source.revision),
        .license = try al.dupe(u8, v.source.license),
        .asset_hash = try al.dupe(u8, v.source.asset_hash),
    };
    return out;
}

fn dupeStrings(al: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try al.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try al.dupe(u8, s);
    return out;
}

fn cloneReport(al: Allocator, r: ImportReport) Allocator.Error!ImportReport {
    const mappings = try al.alloc(vscode.ImportMapping, r.mappings.len);
    for (r.mappings, mappings) |m, *o| o.* = .{ .zeronRole = try al.dupe(u8, m.zeronRole), .vscodeKey = try al.dupe(u8, m.vscodeKey), .value = try al.dupe(u8, m.value) };
    const adjustments = try al.alloc(vscode.ImportAdjustment, r.adjustments.len);
    for (r.adjustments, adjustments) |m, *o| o.* = .{ .zeronRole = try al.dupe(u8, m.zeronRole), .original = try al.dupe(u8, m.original), .resolved = try al.dupe(u8, m.resolved), .reason = try al.dupe(u8, m.reason) };
    const accents = try al.alloc(vscode.AccentCandidate, r.accentCandidates.len);
    for (r.accentCandidates, accents) |m, *o| o.* = .{ .vscodeKey = try al.dupe(u8, m.vscodeKey), .value = try al.dupe(u8, m.value) };
    const validation = try al.alloc(vscode.ReportIssue, r.validation.len);
    for (r.validation, validation) |m, *o| o.* = .{ .variant_id = try al.dupe(u8, m.variant_id), .category = m.category, .severity = m.severity, .message = try al.dupe(u8, m.message) };
    return .{
        .sourceFiles = try dupeStrings(al, r.sourceFiles),
        .sourceHash = try al.dupe(u8, r.sourceHash),
        .mappings = mappings,
        .fallbacks = try dupeStrings(al, r.fallbacks),
        .dropped = try dupeStrings(al, r.dropped),
        .warnings = try dupeStrings(al, r.warnings),
        .adjustments = adjustments,
        .accentCandidates = accents,
        .validation = validation,
    };
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn writeTheme(dir: Io.Dir, name: []const u8, bg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{{ \"name\": \"{s}\", \"type\": \"dark\", \"colors\": {{ \"editor.background\": \"{s}\", \"foreground\": \"#eeeeee\", \"focusBorder\": \"#61afef\" }} }}", .{ name, bg });
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
}

test "install, save, load round-trips a serde-shaped library; ids stay unique" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTheme(tmp.dir, "one.json", "#101820");
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    const theme_path = try std.fs.path.join(testing.allocator, &.{ root, "one.json" });
    defer testing.allocator.free(theme_path);
    var diag: Diagnostic = .{};
    var comp = try compile(testing.allocator, testing.io, theme_path, "custom-one", "one", &diag);
    defer comp.deinit();

    var lib = try Library.init(testing.allocator);
    defer lib.deinit();
    const first = try lib.install(&comp.value, &.{}, .snapshot, &diag);
    try testing.expectEqualStrings("custom-one", first);
    const second = try lib.install(&comp.value, &.{}, .link, &diag);
    try testing.expectEqualStrings("custom-one-2", second);
    try testing.expectEqualStrings("custom-one-2", lib.entry(second).?.family.variants[0].id);
    try testing.expect(lib.entry(second).?.source.isLinked());
    try testing.expect(lib.entry(second).?.report("custom-one-2") != null);
    try lib.save(testing.io, root, &diag);

    var back = try load(testing.allocator, testing.io, root, &diag);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.entries.len);
    const e = back.entry("custom-one").?;
    try testing.expectEqualStrings(theme_path, e.source.imported_snapshot.?);
    try testing.expect(e.family.variants[0].eql(&lib.entry("custom-one").?.family.variants[0]));
    try testing.expectEqualStrings("one.json", std.fs.path.basename(e.report("custom-one").?.sourceFiles[0]));
    // The runtime registry sees the families.
    back.installRuntime();
    defer registry.setCustom(&.{});
    try testing.expect(registry.active().variant("custom-one-2") != null);
    try testing.expect(back.remove("custom-one"));
    try testing.expect(!back.remove("custom-one"));
}

test "linked reload keeps the last good family on failure; unlink and editable copies" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTheme(tmp.dir, "live.json", "#202020");
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "live.json" });
    defer testing.allocator.free(path);
    var diag: Diagnostic = .{};
    var comp = try compile(testing.allocator, testing.io, path, "custom-live", "live", &diag);
    defer comp.deinit();
    var lib = try Library.init(testing.allocator);
    defer lib.deinit();
    const id = try lib.install(&comp.value, &.{}, .link, &diag);

    // A changed source reloads.
    try writeTheme(tmp.dir, "live.json", "#303030");
    try lib.reload(testing.allocator, testing.io, id, &diag);
    try testing.expect(lib.entry(id).?.family.variants[0].colors.background.eql(Color.hex("#303030")));
    // A broken source keeps the family and reports a warning.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "live.json", .data = "{ not json" });
    try testing.expectError(error.LibraryFailed, lib.reload(testing.allocator, testing.io, id, &diag));
    try testing.expect(lib.entry(id).?.status == .warning);
    try testing.expect(lib.entry(id).?.family.variants[0].colors.background.eql(Color.hex("#303030")));
    // Unlink turns it into a snapshot (reload then refuses).
    try lib.unlink(id, &diag);
    try testing.expect(!lib.entry(id).?.source.isLinked());
    try testing.expectError(error.LibraryFailed, lib.reload(testing.allocator, testing.io, id, &diag));
    // Editable duplicate: a native family file that reloads.
    const copy = try lib.duplicateAsEditable(testing.io, id, root, &diag);
    try testing.expectEqualStrings("custom-live-copy", copy);
    try lib.reload(testing.allocator, testing.io, copy, &diag);
    try testing.expectEqualStrings("live Copy", lib.entry(copy).?.family.name);
}
