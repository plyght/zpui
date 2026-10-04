//! Polychrome file icons (vscode-symbols manifest) — port of zeron
//! `file_icons.rs` (`resolve_file`, `well_bg`, dark-appearance color lifts).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");

const Theme = zt.Theme;

const Manifest = struct {
    defs: std.StringHashMapUnmanaged([]const u8) = .empty,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    exts: std.StringHashMapUnmanaged([]const u8) = .empty,
    file: []const u8 = "document",
};

var manifest: ?Manifest = null;
var dark_cache: std.StringHashMapUnmanaged([]const u8) = .empty;
const gpa = std.heap.smp_allocator;

fn lower(s: []const u8) []const u8 {
    const out = gpa.alloc(u8, s.len) catch return s;
    return std.ascii.lowerString(out, s);
}

fn load() *const Manifest {
    if (manifest) |*m| return m;
    var m: Manifest = .{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, assets.file_icons_manifest, .{}) catch {
        manifest = m;
        return &manifest.?;
    };
    if (parsed == .object) {
        const o = parsed.object;
        if (o.get("iconDefinitions")) |defs| if (defs == .object) {
            var it = defs.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .object) if (e.value_ptr.object.get("iconPath")) |p| if (p == .string) {
                const path = if (std.mem.startsWith(u8, p.string, "./icons/")) p.string["./icons/".len..] else p.string;
                m.defs.put(gpa, e.key_ptr.*, path) catch {};
            };
        };
        inline for (.{ .{ "fileNames", "names" }, .{ "fileExtensions", "exts" } }) |pair| {
            if (o.get(pair[0])) |v| if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |e| if (e.value_ptr.* == .string) @field(m, pair[1]).put(gpa, lower(e.key_ptr.*), e.value_ptr.string) catch {};
            };
        }
        if (o.get("file")) |f| if (f == .string) {
            m.file = f.string;
        };
    }
    manifest = m;
    return &manifest.?;
}

fn definitionAsset(m: *const Manifest, def_in: []const u8) ?[]const u8 {
    const def = if (std.mem.eql(u8, def_in, "less")) "brackets-sky" else if (std.mem.eql(u8, def_in, "yml")) "yaml" else def_in;
    return m.defs.get(def);
}

/// The manifest-relative asset path (`files/zig.svg`) for a file path.
pub fn assetFor(path: []const u8) []const u8 {
    const m = load();
    var name = path;
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| name = path[i + 1 ..];
    var buf: [128]u8 = undefined;
    const lname = if (name.len <= buf.len) std.ascii.lowerString(buf[0..name.len], name) else name;
    if (m.names.get(lname)) |d| if (definitionAsset(m, d)) |a| return a;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, lname, i, '.')) |dot| : (i = dot + 1) {
        const ext = lname[dot + 1 ..];
        if (ext.len == 0) continue;
        if (m.exts.get(ext)) |d| if (definitionAsset(m, d)) |a| return a;
    }
    return definitionAsset(m, m.file) orelse "files/document.svg";
}

/// SVG bytes for the icon, with zeron's dark-appearance color lifts applied.
pub fn svgFor(path: []const u8, dark: bool) ?[]const u8 {
    const asset = assetFor(path);
    const bytes = assets.fileIcon(asset) orelse return null;
    if (!dark) return bytes;
    if (dark_cache.get(asset)) |b| return b;
    var out: []const u8 = bytes;
    for (assets.file_icon_dark_swaps) |swap| {
        inline for (.{ false, true }) |lc| {
            var from_buf: [7]u8 = undefined;
            var to_buf: [7]u8 = undefined;
            const from = if (lc) std.ascii.lowerString(&from_buf, swap[0]) else swap[0];
            const to = if (lc) std.ascii.lowerString(&to_buf, swap[1]) else swap[1];
            if (std.mem.indexOf(u8, out, from) != null) {
                const next = std.mem.replaceOwned(u8, gpa, out, from, to) catch out;
                out = next;
            }
        }
    }
    dark_cache.put(gpa, asset, out) catch {};
    return out;
}

/// The icon element (decorative, polychrome → `img`).
pub fn icon(path: []const u8, theme: *const Theme, size: f32) zpui.AnyElement {
    const bytes = svgFor(path, theme.appearance == .dark) orelse return zpui.empty();
    return zpui.intoAnyElement(zpui.img(zpui.ImageSource{ .image = .fromBytes(bytes) }).size(zpui.px(size)).flexNone());
}

/// The rounded well behind a file icon (`file_icons::well_bg`).
pub fn wellBg(theme: *const Theme) zpui.Hsla {
    const alpha: f32 = if (theme.isFrost()) 0.32 else 0.16;
    return switch (theme.appearance) {
        .dark => zpui.color.black.alpha(alpha),
        .light => zpui.color.white.alpha(alpha),
    };
}

test "resolves by extension and name" {
    try std.testing.expect(std.mem.indexOf(u8, assetFor("src/main.rs"), "rust") != null);
    try std.testing.expect(assets.fileIcon(assetFor("Cargo.toml")) != null);
}
