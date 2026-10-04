//! Build wiring for the vendored libghostty-vt (Ghostty's terminal core,
//! ported to Zig 0.17). Imported from the top-level build.zig.
//!
//! Produces a `ghostty-vt` module rooted at `src/lib_vt.zig` with the same
//! anonymous/named imports Ghostty's own build (src/build/GhosttyZig.zig)
//! provides:
//!   - `terminal_options`  (src/terminal/build_options.zig Options.add)
//!   - `build_options`     (only the `simd` flag is read by the vt closure)
//!   - `unicode_tables` / `symbols_tables` (pre-generated, see generated/)
//!   - `uucode`            (vendored uucode runtime with pre-generated tables)
//!
//! Configuration: artifact=.lib, simd=false (no C++ simdutf/highway),
//! oniguruma=false, kitty_graphics=false (needs wuffs), c_abi=false.
const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Ghostty's expensive integrity checks. Default: Debug only (like
    /// upstream). The upstream test suite needs it on (some tests assert it).
    slow_runtime_safety: ?bool = null,
};

/// Path of this directory relative to the build root.
const root = "vendor/ghostty-vt/";

pub fn module(b: *std.Build, opts: Options) *std.Build.Module {
    const target = opts.target;
    const optimize = opts.optimize;

    // ---- uucode (runtime lib with pre-generated tables) ----
    const uu_types = b.createModule(.{
        .root_source_file = b.path(root ++ "uucode/src/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const uu_config = b.createModule(.{
        .root_source_file = b.path(root ++ "uucode/src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    uu_config.addImport("types.zig", uu_types);
    const uu_storage = b.createModule(.{
        .root_source_file = b.path(root ++ "uucode/src/storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    uu_config.addImport("storage.zig", uu_storage);
    uu_storage.addImport("config.zig", uu_config);
    const uu_build_config = b.createModule(.{
        .root_source_file = b.path(root ++ "uucode/uucode_runtime_config.zig"),
        .target = target,
        .optimize = optimize,
    });
    uu_build_config.addImport("config.zig", uu_config);
    uu_build_config.addImport("storage.zig", uu_storage);
    const uu_tables = b.createModule(.{
        .root_source_file = b.path(root ++ "generated/uucode_tables.zig"),
        .target = target,
        .optimize = optimize,
    });
    uu_tables.addImport("config.zig", uu_config);
    uu_tables.addImport("storage.zig", uu_storage);
    uu_tables.addImport("build_config", uu_build_config);
    const uucode = b.createModule(.{
        .root_source_file = b.path(root ++ "uucode/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    uucode.addImport("types.zig", uu_types);
    uucode.addImport("config.zig", uu_config);
    uucode.addImport("tables", uu_tables);

    // ---- ghostty-vt ----
    const vt = b.createModule(.{
        .root_source_file = b.path(root ++ "src/lib_vt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const general = b.addOptions();
    general.addOption(bool, "simd", false);
    general.addOption(bool, "wasm_shared", false);
    vt.addOptions("build_options", general);

    const t = b.addOptions();
    t.addOption(Artifact, "artifact", .lib);
    t.addOption(bool, "c_abi", false);
    t.addOption(bool, "oniguruma", false);
    t.addOption(bool, "simd", false);
    // Ghostty enables slow safety checks in Debug (some tests assert it).
    t.addOption(bool, "slow_runtime_safety", opts.slow_runtime_safety orelse (optimize == .debug));
    t.addOption(bool, "tmux_control_mode", false);
    // Snapshot (state serialization) is unused by zeron and its tests need
    // build-generated golden files; disabled.
    t.addOption(bool, "snapshot", false);
    t.addOption(bool, "formatter", true);
    t.addOption(bool, "selection", true);
    t.addOption(bool, "search", true);
    t.addOption(bool, "render_state", true);
    t.addOption(bool, "input_encode", true);
    t.addOption(bool, "color", true);
    t.addOption(bool, "grid_introspection", true);
    t.addOption(bool, "glyph_protocol", true);
    t.addOption(bool, "kitty_graphics", false);
    t.addOption([]const u8, "version_string", "0.1.0-zpui");
    t.addOption(usize, "version_major", 0);
    t.addOption(usize, "version_minor", 1);
    t.addOption(usize, "version_patch", 0);
    t.addOption(?[]const u8, "version_pre", "zpui");
    t.addOption(?[]const u8, "version_build", null);
    vt.addOptions("terminal_options", t);

    vt.addAnonymousImport("unicode_tables", .{
        .root_source_file = b.path(root ++ "generated/props.zig"),
    });
    vt.addAnonymousImport("symbols_tables", .{
        .root_source_file = b.path(root ++ "generated/symbols.zig"),
    });
    vt.addImport("uucode", uucode);
    return vt;
}

/// Mirrors src/terminal/build_options.zig `Options.Artifact` so the
/// generated options module has a compatible enum.
pub const Artifact = enum { ghostty, lib };
