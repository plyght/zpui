//! File / folder identity icons for the explorer — zeron `file_icons.rs`
//! `FileIconIdentity::{file, directory, symlink}`. Files resolve through the
//! shared `markdown/file_icons.zig`; folders resolve `folderNames` (then the
//! generic `folder`) from the same vscode-symbols manifest, with the dark
//! appearance color lifts applied.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");
const md = @import("zeron_ui_markdown");

const gpa = std.heap.smp_allocator;

const FolderManifest = struct {
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    defs: std.StringHashMapUnmanaged([]const u8) = .empty,
    folder: []const u8 = "folder",
};

var manifest: ?FolderManifest = null;
var dark_cache: std.StringHashMapUnmanaged([]const u8) = .empty;

fn load() *const FolderManifest {
    if (manifest) |*m| return m;
    var m: FolderManifest = .{};
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
        if (o.get("folderNames")) |v| if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .string) {
                const lower = std.ascii.allocLowerString(gpa, e.key_ptr.*) catch continue;
                m.names.put(gpa, lower, e.value_ptr.string) catch {};
            };
        };
        if (o.get("folder")) |f| if (f == .string) {
            m.folder = f.string;
        };
    }
    manifest = m;
    return &manifest.?;
}

/// Manifest-relative asset for a directory name (`folders/folder-orange-code.svg`).
pub fn folderAsset(name: []const u8) []const u8 {
    const m = load();
    var buf: [128]u8 = undefined;
    const lname = if (name.len <= buf.len) std.ascii.lowerString(buf[0..name.len], name) else name;
    if (m.names.get(lname)) |d| if (m.defs.get(d)) |a| return a;
    return m.defs.get(m.folder) orelse "folders/folder.svg";
}

fn darkened(asset: []const u8, bytes: []const u8) []const u8 {
    if (dark_cache.get(asset)) |b| return b;
    var out: []const u8 = bytes;
    for (assets.file_icon_dark_swaps) |swap| {
        inline for (.{ false, true }) |lc| {
            var from_buf: [7]u8 = undefined;
            var to_buf: [7]u8 = undefined;
            const from = if (lc) std.ascii.lowerString(&from_buf, swap[0]) else swap[0];
            const to = if (lc) std.ascii.lowerString(&to_buf, swap[1]) else swap[1];
            if (std.mem.indexOf(u8, out, from) != null) out = std.mem.replaceOwned(u8, gpa, out, from, to) catch out;
        }
    }
    dark_cache.put(gpa, asset, out) catch {};
    return out;
}

pub fn folderIcon(name: []const u8, theme: *const zt.Theme, size: f32) zpui.AnyElement {
    const asset = folderAsset(name);
    const raw = assets.fileIcon(asset) orelse assets.fileIcon("folders/folder.svg") orelse return zpui.empty();
    const bytes = if (theme.appearance == .dark) darkened(asset, raw) else raw;
    return zpui.intoAnyElement(zpui.img(zpui.ImageSource{ .image = .fromBytes(bytes) }).size(zpui.px(size)).flexNone());
}

pub const Identity = enum { file, directory, symlink };

/// The icon for an explorer row.
pub fn entryIcon(kind: Identity, name: []const u8, theme: *const zt.Theme, size: f32) zpui.AnyElement {
    return switch (kind) {
        .directory => folderIcon(name, theme, size),
        .file, .symlink => md.file_icons.icon(name, theme, size),
    };
}

test "folder names resolve" {
    try std.testing.expect(std.mem.indexOf(u8, folderAsset("src"), "code") != null);
    try std.testing.expect(std.mem.indexOf(u8, folderAsset("unknown-dir-xyz"), "folder") != null);
}
