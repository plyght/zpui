const std = @import("std");

/// `-Dtest-filter` for the zeron app tests too (`zig build zeron-app-test -Dtest-filter=scroll`).
var app_test_filters: []const []const u8 = &.{};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpui = b.addModule("zpui", .{
        .root_source_file = b.path("src/zpui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose names contain this (repeatable; zpui-test, zeron-app-test)") orelse &.{};
    app_test_filters = test_filters;
    const tests = b.addTest(.{ .root_module = zpui, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zpui unit tests");
    test_step.dependOn(&run_tests.step);
    b.step("zpui-test", "Run only the zpui framework tests (-Dtest-filter=... to narrow)").dependOn(&run_tests.step);

    addZeronEngine(b, target, optimize, test_step);
    addZeronDesign(b, target, optimize, zpui, test_step);
    addVulkanRenderer(b, target, optimize, zpui);
    addLinuxPlatform(b, target, optimize, zpui);
    addLinuxText(b, target, optimize, zpui);
    addMetalRenderer(b, target, optimize, zpui);
    addMacPlatform(b, target, optimize, zpui);
    addOverlayDemo(b, target, optimize, zpui);
    addWindowsPlatform(b, target, optimize, zpui);
    addZeronSyntax(b, target, optimize, test_step);
    addImageSupport(b, target, optimize, zpui);
    addZeronMarkdownDiff(b, target, optimize, test_step);
    addZeronModel(b, target, optimize, zpui, test_step);
    addHelloExample(b, target, optimize, zpui);
    addZeronTerminal(b, target, optimize, zpui, test_step);
    addZeronComposer(b, target, optimize, zpui, test_step);
    addZeronTranscriptUi(b, target, optimize, zpui, test_step);
    addZeronApp(b, target, optimize, zpui, test_step);
    addListDemo(b, target, optimize, zpui);
    addPrefsDemo(b, target, optimize, zpui);
    addGlyphTransformDemo(b, target, optimize, zpui);
    addZeronRightPane(b, target, optimize, zpui, test_step);
    addZeronPackaging(b, target);
    addZeronFiles(b, target, optimize, zpui, test_step);
    addZeronBrowserHelper(b, target);
    addZeronMedia(b, target, optimize, zpui, test_step);
    addZeronLifecycle(b);
    addZeronVoice(b, target, optimize, zpui);
    addAudio(b, target, optimize, zpui, test_step);
}

/// zeron on-device dictation engine (apps/zeron/src/voice, port of zeron
/// `crates/voice`): `zig build voice-test` runs its tests — resampler and
/// log-mel parity with the Rust fixtures, the session coordinator, model
/// management, and (with `ZERON_VOICE_MODEL=<dir>` and an ONNX Runtime from
/// `ZERON_ONNXRUNTIME=<lib>`) an end-to-end transcription of
/// apps/zeron/fixtures/voice/speech.wav. The app itself imports the same
/// files from apps/zeron/src/main.zig.
fn addZeronVoice(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zpui: *std.Build.Module) void {
    const voice = b.createModule(.{
        .root_source_file = b.path("apps/zeron/src/voice/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zpui", .module = zpui }},
    });
    const run = b.addRunArtifact(b.addTest(.{ .name = "zeron_voice", .root_module = voice }));
    run.setCwd(b.path("."));
    b.step("voice-test", "Run the zeron dictation engine tests (ZERON_VOICE_MODEL / ZERON_ONNXRUNTIME enable the end-to-end transcript)").dependOn(&run.step);
}

/// zeron engine client library (apps/zeron/src/engine), its tests, and the
/// `zeron-probe` CLI (`zig build probe -- --help`).
fn addZeronEngine(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const engine = b.addModule("zeron_engine", .{
        .root_source_file = b.path("apps/zeron/src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_tests = b.addTest(.{ .root_module = engine });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    test_step.dependOn(&run_engine_tests.step);
    b.step("zeron-engine-test", "Run only the zeron engine client tests (ws, rpc, protocol, connect)").dependOn(&run_engine_tests.step);

    const probe = b.addExecutable(.{
        .name = "zeron-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zeron/examples/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zeron_engine", .module = engine }},
        }),
    });
    b.installArtifact(probe);
    const run_probe = b.addRunArtifact(probe);
    run_probe.addPassthruArgs();
    const probe_step = b.step("probe", "Run zeron-probe against a local engine");
    probe_step.dependOn(&run_probe.step);
}

/// Vulkan renderer (src/renderer/vulkan/) on non-Apple targets: Vulkan C
/// bindings via translate-c, GLSL shaders compiled to SPIR-V with `glslc`
/// and embedded through a generated `vulkan_shaders` module, plus the
/// `render-test` golden-image harness (`zig build render-test`).
fn addVulkanRenderer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    const os = target.result.os.tag;
    // Apple targets render with Metal, Windows with D3D11 (addWindowsPlatform).
    if (os.isDarwin() or os == .windows) return;

    const vk_c = b.addTranslateC(.{
        .root_source_file = b.path("src/renderer/vulkan/vk.h"),
        .target = target,
        .optimize = optimize,
    });
    // Named module "vk_c" (raw Vulkan C API), reusable by the Linux platform layer.
    zpui.addImport("vk_c", vk_c.addModule("vk_c"));
    zpui.link_libc = true;
    zpui.linkSystemLibrary("vulkan", .{});

    const shader_dir = "src/renderer/vulkan/shaders/";
    const shaders = [_][]const u8{
        "quad.vert",               "quad.frag",
        "shadow.vert",             "shadow.frag",
        "underline.vert",          "underline.frag",
        "mono_sprite.vert",        "mono_sprite.frag",
        "subpixel_sprite.frag",    "subpixel_sprite_fallback.frag",
        "poly_sprite.vert",        "poly_sprite.frag",
        "path_rasterization.vert", "path_rasterization.frag",
        "path_sprite.vert",        "path_sprite.frag",
        "blur_pass.vert",          "blur_pass.frag",
        "backdrop_blur.vert",      "backdrop_blur.frag",
    };
    const wf = b.addWriteFiles();
    var index: std.ArrayList(u8) = .empty;
    index.appendSlice(b.allocator, "//! Generated by build.zig: SPIR-V for src/renderer/vulkan/shaders.\n") catch @panic("OOM");
    for (shaders) |name| {
        const spv = b.fmt("{s}.spv", .{name});
        const glslc = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O", "-MD" });
        glslc.addArg("-MF");
        _ = glslc.addDepFileOutputArg(b.fmt("{s}.d", .{name}));
        glslc.addFileArg(b.path(b.fmt("{s}{s}", .{ shader_dir, name })));
        glslc.addArg("-o");
        _ = wf.addCopyFile(glslc.addOutputFileArg(spv), spv);
        const ident = b.allocator.dupe(u8, name) catch @panic("OOM");
        for (ident) |*c| if (c.* == '.') {
            c.* = '_';
        };
        index.print(b.allocator, "pub const {s} align(4) = @embedFile(\"{s}\").*;\n", .{ ident, spv }) catch @panic("OOM");
    }
    const shaders_mod = b.createModule(.{ .root_source_file = wf.add("shaders.zig", index.items) });
    zpui.addImport("vulkan_shaders", shaders_mod);

    const render_test = b.addExecutable(.{
        .name = "render-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/render_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    b.installArtifact(render_test);
    const run = b.addRunArtifact(render_test);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("render-test", "Render the showcase scene offscreen to zig-out/render-test.png and compare with tests/golden");
    step.dependOn(&run.step);
}

/// Linux platform backend (src/platform/linux/): wayland-scanner protocol
/// bindings, the `linux_c` translate-c module (wayland, xkbcommon, Xlib/xcb),
/// system libraries, and the `linux-window` demo (`zig build linux-window`).
fn addLinuxPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (target.result.os.tag != .linux) return;

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/linux/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const protocols = [_][]const u8{
        "xdg-shell",              "xdg-decoration-unstable-v1", "fractional-scale-v1",
        "viewporter",             "tablet-v2",                  "cursor-shape-v1",
        "text-input-unstable-v3", "org-kde-kwin-blur",          "wlr-layer-shell-unstable-v1",
        "wlr-foreign-toplevel-management-unstable-v1",
    };
    for (protocols) |name| {
        const xml = b.path(b.fmt("src/platform/linux/protocols/{s}.xml", .{name}));
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header.addFileArg(xml);
        c.addIncludePath(header.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{name})).dirname());
        const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code.addFileArg(xml);
        zpui.addCSourceFile(.{ .file = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{name})) });
    }
    zpui.addImport("linux_c", c.createModule());
    zpui.link_libc = true;
    for ([_][]const u8{
        "wayland-client", "wayland-cursor", "xkbcommon", "xkbcommon-x11",
        "X11",            "X11-xcb",        "xcb",       "xcb-xkb",
        "Xcursor",        "Xi",             "Xext",
    }) |lib| zpui.linkSystemLibrary(lib, .{});

    const demo = b.addExecutable(.{
        .name = "linux-window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/linux_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    run.addPassthruArgs();
    const step = b.step("linux-window", "Open the Linux platform demo window (Wayland or X11)");
    step.dependOn(&run.step);
}

/// Metal renderer (src/renderer/metal/) on Apple targets: system frameworks,
/// the `render-test` harness, and `metal-check`, which compiles the renderer
/// and showcase scene to an object file. Cross builds from non-macOS hosts
/// have no SDK to link frameworks against, so there `zig build` only runs
/// `metal-check` (`zig build -Dtarget=aarch64-macos`); CI links and runs on macOS.
fn addMetalRenderer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (!target.result.os.tag.isDarwin()) return;
    const native = @import("builtin").os.tag.isDarwin();

    const check = b.addObject(.{
        .name = "metal-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/metal_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    const install_check = b.addInstallFile(check.getEmittedBin(), "metal-check.o");
    const check_step = b.step("metal-check", "Compile the Metal renderer to zig-out/metal-check.o (no SDK needed)");
    check_step.dependOn(&install_check.step);
    const font_compare = addFontCompare(b, target, optimize, zpui, native);
    if (!native) {
        b.getInstallStep().dependOn(&install_check.step);
        return;
    }

    zpui.link_libc = true;
    // An explicit -Dtarget (e.g. x86_64 on an arm64 Mac) drops the native SDK search paths;
    // pass `-Dmacos-sdk=$(xcrun --show-sdk-path)` to point the linker at the SDK explicitly.
    if (b.option([]const u8, "macos-sdk", "macOS SDK path for explicit -Dtarget builds on a Mac")) |sdk| {
        zpui.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        zpui.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        zpui.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    }
    zpui.linkSystemLibrary("objc", .{});
    for ([_][]const u8{ "Foundation", "CoreGraphics", "QuartzCore", "Metal" }) |name| zpui.linkFramework(name, .{});
    // Only reached through objc_getClass("MPSImageGaussianBlur"); keep it linked.
    zpui.linkFramework("MetalPerformanceShaders", .{ .needed = true });

    const render_test = b.addExecutable(.{
        .name = "render-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/render_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    b.installArtifact(render_test);
    const run = b.addRunArtifact(render_test);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("render-test", "Render the showcase scene offscreen with Metal to zig-out/render-test.png");
    step.dependOn(&run.step);
    if (font_compare) |fc| {
        const fc_run = b.addRunArtifact(fc);
        fc_run.setCwd(b.path("."));
        fc_run.addPassthruArgs();
        b.step("font-compare", "Render tools/font-compare/cases.json with zpui (Metal + CoreText) to zig-out/font-compare").dependOn(&fc_run.step);
    }
}

/// tools/font-compare: zpui's half of the native-vs-zpui system font comparison
/// (`font-compare-check` compiles it without an SDK; `font-compare` runs it on a Mac).
fn addFontCompare(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zpui: *std.Build.Module, native: bool) ?*std.Build.Step.Compile {
    const png = b.createModule(.{ .root_source_file = b.path("examples/png.zig"), .target = target, .optimize = optimize });
    const root = b.createModule(.{
        .root_source_file = b.path("tools/font-compare/zpui_render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zpui", .module = zpui }, .{ .name = "png", .module = png } },
    });
    const check = b.addObject(.{ .name = "font-compare-check", .root_module = root });
    b.step("font-compare-check", "Compile tools/font-compare/zpui_render.zig (no SDK needed)").dependOn(&b.addInstallFile(check.getEmittedBin(), "font-compare-check.o").step);
    if (!native) return null;
    return b.addExecutable(.{ .name = "font-compare", .root_module = root });
}

/// zeron design system: `zeron_theme` (apps/zeron/src/theme) and
/// `zeron_assets` (generated apps/zeron/src/assets.zig, compiled next to a
/// copy of apps/zeron/assets/ so its @embedFile paths resolve), plus tests.
fn addZeronDesign(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const theme = b.addModule("zeron_theme", .{
        .root_source_file = b.path("apps/zeron/src/theme/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zpui", .module = zpui }},
    });
    const theme_tests = b.addRunArtifact(b.addTest(.{ .root_module = theme }));
    theme_tests.setCwd(b.path("."));
    test_step.dependOn(&theme_tests.step);
    b.step("zeron-theme-test", "Run only the zeron_theme tests (themes, VS Code importer, theme library)").dependOn(&theme_tests.step);

    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("apps/zeron/assets"), "assets", .{});
    const assets = b.addModule("zeron_assets", .{
        .root_source_file = files.addCopyFile(b.path("apps/zeron/src/assets.zig"), "assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = assets })).step);
}

/// Linux text backend (src/text/freetype.zig): FreeType, HarfBuzz and fontconfig
/// via the `freetype_c` translate-c module, plus the `text-dump` CPU raster check
/// (`zig build text-dump` writes zig-out/text-dump.png).
fn addLinuxText(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (target.result.os.tag != .linux) return;
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/text/freetype_c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addSystemIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    c.addSystemIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    zpui.addImport("freetype_c", c.createModule());
    zpui.link_libc = true;
    for ([_][]const u8{ "freetype2", "harfbuzz", "fontconfig" }) |lib| zpui.linkSystemLibrary(lib, .{});

    const dump = b.addExecutable(.{
        .name = "text-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/text_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    b.installArtifact(dump);
    const run = b.addRunArtifact(dump);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("text-dump", "Rasterize a sample paragraph on the CPU to zig-out/text-dump.png");
    step.dependOn(&run.step);
}

/// macOS platform backend (src/platform/mac/) + CoreText (src/text/coretext.zig):
/// AppKit/CoreText/CoreVideo/Carbon frameworks, the `mac-window` demo
/// (`zig build mac-window`; `ZPUI_SMOKE_FRAMES=30` makes it render 30 frames,
/// write zig-out/mac-window*.png and exit), and `mac-check`, an object-only
/// compile of the backend that works from non-macOS hosts without an SDK.
fn addMacPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (target.result.os.tag != .macos) return;
    const native = @import("builtin").os.tag == .macos;

    const check = b.addObject(.{
        .name = "mac-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mac_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    const install_check = b.addInstallFile(check.getEmittedBin(), "mac-check.o");
    const check_step = b.step("mac-check", "Compile the macOS platform backend + demo to zig-out/mac-check.o (no SDK needed)");
    check_step.dependOn(&install_check.step);
    // The overlay demo (examples/overlay_demo.zig) against the macOS backend, too.
    const overlay_check = b.addObject(.{
        .name = "overlay-demo-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/overlay_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    check_step.dependOn(&b.addInstallFile(overlay_check.getEmittedBin(), "overlay-demo-check.o").step);
    if (!native) {
        b.getInstallStep().dependOn(&install_check.step);
        return;
    }

    zpui.link_libc = true;
    for ([_][]const u8{ "AppKit", "CoreFoundation", "CoreText", "CoreVideo", "Carbon" }) |name| zpui.linkFramework(name, .{});

    const demo = b.addExecutable(.{
        .name = "mac-window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mac_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("mac-window", "Run the macOS window demo (ZPUI_SMOKE_FRAMES=N for the CI smoke test)");
    step.dependOn(&run.step);
}

/// `overlay-demo` (examples/overlay_demo.zig, docs/DESKTOP_OVERLAY.md): a transparent
/// always-on-top overlay with a blob pulsing on global key events, an aspect-locked
/// resize handle and a tray item. `ZPUI_SMOKE_FRAMES=N` renders N frames, checks that
/// nothing is drawn while idle, writes zig-out/overlay-demo.png and exits. Native
/// Linux and macOS hosts only.
fn addOverlayDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    const os = target.result.os.tag;
    if (os != .linux and !(os == .macos and @import("builtin").os.tag == .macos)) return;
    const demo = b.addExecutable(.{
        .name = "overlay-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/overlay_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("overlay-demo", "Run the desktop overlay demo (ZPUI_SMOKE_FRAMES=N for the smoke test)");
    step.dependOn(&run.step);
    b.step("overlay-demo-build", "Build only the overlay demo to zig-out/bin/overlay-demo").dependOn(&b.addInstallArtifact(demo, .{}).step);
}

/// Windows platform backend (src/platform/windows/) + the D3D11 renderer
/// (src/renderer/d3d11/, HLSL compiled at runtime with D3DCompile) + DirectWrite
/// (src/text/directwrite.zig). Only system DLLs are linked (MinGW import libraries
/// ship with Zig, so cross builds from Linux/macOS work). The `windows-window` demo
/// (`zig build windows-window`; `ZPUI_SMOKE_FRAMES=30` renders 30 frames of a normal
/// window, a transparent overlay and a native-controls panel, writes
/// zig-out/windows-*.png and exits) embeds src/platform/windows/zpui.manifest
/// (per-monitor-v2 DPI, comctl32 v6); apps should do the same (`windowsManifest`).
fn addWindowsPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (target.result.os.tag != .windows) return;
    zpui.link_libc = true;
    for ([_][]const u8{
        "user32", "gdi32",   "kernel32", "advapi32", "shell32",        "ole32",
        "dwmapi", "uxtheme", "comctl32", "imm32",    "d3d11",          "dxgi",
        "dcomp",  "dwrite",  "shcore",   "version",  "d3dcompiler_47",
    }) |lib| zpui.linkSystemLibrary(lib, .{});

    const demo = b.addExecutable(.{
        .name = "windows-window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/windows_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    demo.win32_manifest = windowsManifest(b);
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const native = @import("builtin").os.tag == .windows;
    const step = b.step("windows-window", "Run the Windows window/overlay/native-controls demo (ZPUI_SMOKE_FRAMES=N for the CI smoke test)");
    // Cross builds can only compile: install the exe instead of running it.
    if (native) step.dependOn(&run.step) else step.dependOn(&b.addInstallArtifact(demo, .{}).step);

    // The cross-platform overlay demo (examples/overlay_demo.zig) on the Windows backend.
    const overlay = b.addExecutable(.{
        .name = "overlay-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/overlay_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    overlay.win32_manifest = windowsManifest(b);
    const overlay_install = b.addInstallArtifact(overlay, .{});
    const overlay_run = b.addRunArtifact(overlay);
    overlay_run.setCwd(b.path("."));
    overlay_run.addPassthruArgs();
    b.step("overlay-demo", "Run the desktop overlay demo (ZPUI_SMOKE_FRAMES=N for the smoke test)").dependOn(if (native) &overlay_run.step else &overlay_install.step);
    b.step("overlay-demo-build", "Build only the overlay demo to zig-out/bin/overlay-demo.exe").dependOn(&overlay_install.step);

    // The preferences demo (examples/prefs_demo.zig): real Win32 controls in the grouped form.
    const prefs = b.addExecutable(.{
        .name = "prefs-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/prefs_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    prefs.win32_manifest = windowsManifest(b);
    const prefs_install = b.addInstallArtifact(prefs, .{});
    const prefs_run = b.addRunArtifact(prefs);
    prefs_run.setCwd(b.path("."));
    prefs_run.addPassthruArgs();
    b.step("prefs-demo", "Run the preferences window demo (ZPUI_SMOKE_FRAMES=N captures zig-out/prefs-demo.png)").dependOn(if (native) &prefs_run.step else &prefs_install.step);
}

/// The application manifest Windows executables built on zpui should embed
/// (`exe.win32_manifest = windowsManifest(b)`): per-monitor-v2 DPI awareness and
/// comctl32 v6 (themed native controls).
pub fn windowsManifest(b: *std.Build) std.Build.LazyPath {
    return b.path("src/platform/windows/zpui.manifest");
}

/// zeron syntax highlighting (apps/zeron/src/syntax): the vendored tree-sitter
/// runtime + grammars (vendor/tree-sitter/tree_sitter_build.zig), the
/// `zeron_syntax` module, and its tests.
fn addZeronSyntax(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const ts = @import("vendor/tree-sitter/tree_sitter_build.zig").add(b, target, optimize);
    const syntax = b.addModule("zeron_syntax", .{
        .root_source_file = b.path("apps/zeron/src/syntax/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ts.addTo(syntax);
    const run = b.addRunArtifact(b.addTest(.{ .root_module = syntax }));
    test_step.dependOn(&run.step);
    b.step("syntax-test", "Run only the zeron_syntax tests").dependOn(&run.step);
}

/// Image + SVG support (src/image/): the vendored lunasvg/plutovg, stb_image
/// and simplewebp compiled into `zpui` (src/image/image_build.zig), plus the
/// `icon-sheet` visual check (`zig build icon-sheet` writes zig-out/icon-sheet.png).
fn addImageSupport(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    @import("src/image/image_build.zig").add(b, zpui);

    const sheet = b.addExecutable(.{
        .name = "icon-sheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/icon_sheet.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    const run = b.addRunArtifact(sheet);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("icon-sheet", "Rasterize every zeron icon + sample images to zig-out/icon-sheet.png");
    step.dependOn(&run.step);
}

/// zeron markdown (apps/zeron/src/markdown: pulldown-cmark 0.12 port, block
/// model, incremental reparse, streaming mend) and diff (apps/zeron/src/diff:
/// unified patch parser, `similar` Myers/Patience port) modules + their
/// parity tests.
fn addZeronMarkdownDiff(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    inline for (.{
        .{ "zeron_markdown", "apps/zeron/src/markdown/root.zig" },
        .{ "zeron_diff", "apps/zeron/src/diff/root.zig" },
    }) |m| {
        const mod = b.addModule(m[0], .{
            .root_source_file = b.path(m[1]),
            .target = target,
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = m[0], .root_module = mod })).step);
    }
}

/// zeron app state (apps/zeron/src/model: view logic, settings, engine-backed
/// stores as zpui entities) and the `zeron_actions` module
/// (apps/zeron/src/actions.zig + keymap.zig). `zig build zeron-view-test`
/// runs only the pure parts (no zpui); `zig build zeron-model-test` runs all.
/// `-Dzeron-live=/path/to/zeron` adds a live test against `zeron headless`.
fn addZeronModel(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const engine = b.modules.get("zeron_engine").?;
    const theme = b.modules.get("zeron_theme").?;
    const options = b.addOptions();
    options.addOption(?[]const u8, "live_zeron", b.option([]const u8, "zeron-live", "Path to a zeron binary for the live model test"));

    const pure = b.createModule(.{
        .root_source_file = b.path("apps/zeron/src/model/pure_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zeron_engine", .module = engine },
            .{ .name = "zeron_theme", .module = theme },
        },
    });
    const run_pure = b.addRunArtifact(b.addTest(.{ .name = "zeron_view", .root_module = pure }));
    b.step("zeron-view-test", "Run the pure zeron model tests (view parity, settings)").dependOn(&run_pure.step);

    const model = b.addModule("zeron_model", .{
        .root_source_file = b.path("apps/zeron/src/model/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_engine", .module = engine },
            .{ .name = "zeron_theme", .module = theme },
            .{ .name = "model_options", .module = options.createModule() },
        },
    });
    const actions = b.addModule("zeron_actions", .{
        .root_source_file = b.path("apps/zeron/src/actions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_model", .module = model },
        },
    });
    const run_model = b.addRunArtifact(b.addTest(.{ .name = "zeron_model", .root_module = model }));
    const run_actions = b.addRunArtifact(b.addTest(.{ .name = "zeron_actions", .root_module = actions }));
    const model_step = b.step("zeron-model-test", "Run the zeron model + actions tests");
    model_step.dependOn(&run_pure.step);
    model_step.dependOn(&run_model.step);
    model_step.dependOn(&run_actions.step);
    test_step.dependOn(model_step);
}

/// `zig build hello`: the gpui-style Counter example (examples/hello.zig) on the Linux
/// backend, with Geist fonts and icons from `zeron_assets`.
fn addHelloExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (target.result.os.tag != .linux) return;
    const assets = b.modules.get("zeron_assets") orelse return;
    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpui", .module = zpui },
                .{ .name = "zeron_assets", .module = assets },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const step = b.step("hello", "Run the zpui hello example (Counter view)");
    step.dependOn(&run.step);
}

/// zeron terminal core: vendored Ghostty VT (vendor/ghostty-vt, ported to Zig
/// 0.17; `ghostty-vt` module) + the zeron wrapper (apps/zeron/src/terminal,
/// `zeron_terminal`). `zig build terminal-test` runs only the wrapper tests;
/// `zig build ghostty-vt-test` runs the full vendored Ghostty suite (~2.8k
/// tests, slow in Debug); `zig build term-dump` renders a shell command's
/// final screen to zig-out/term-dump.png (Linux, FreeType text system).
fn addZeronTerminal(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const vt = @import("vendor/ghostty-vt/module.zig").module(b, .{ .target = target, .optimize = optimize });
    const term = b.addModule("zeron_terminal", .{
        .root_source_file = b.path("apps/zeron/src/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // pty.zig (forkpty)
        .imports = &.{.{ .name = "ghostty-vt", .module = vt }},
    });
    const term_tests = b.addRunArtifact(b.addTest(.{ .root_module = term }));
    term_tests.setCwd(b.path("."));
    test_step.dependOn(&term_tests.step);
    b.step("terminal-test", "Run only the zeron_terminal tests").dependOn(&term_tests.step);

    const vt_test_mod = @import("vendor/ghostty-vt/module.zig").module(b, .{ .target = target, .optimize = optimize, .slow_runtime_safety = true });
    const vt_tests = b.addRunArtifact(b.addTest(.{ .root_module = vt_test_mod }));
    vt_tests.setCwd(b.path("vendor/ghostty-vt")); // snapshot golden files are cwd-relative
    b.step("ghostty-vt-test", "Run the vendored Ghostty terminal test suite").dependOn(&vt_tests.step);

    if (target.result.os.tag != .linux) return;
    const theme = b.modules.get("zeron_theme") orelse return;
    const dump = b.addExecutable(.{
        .name = "term-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/term_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpui", .module = zpui },
                .{ .name = "zeron_terminal", .module = term },
                .{ .name = "zeron_theme", .module = theme },
            },
        }),
    });
    b.installArtifact(dump);
    const run = b.addRunArtifact(dump);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("term-dump", "Run a command under a PTY and render the terminal to zig-out/term-dump.png").dependOn(&run.step);
}

/// zeron text editor + composer: `zeron_input` (apps/zeron/src/ui/input: the
/// reusable `TextInput` editor, port of Rust `ComposerInput`) and
/// `zeron_composer` (apps/zeron/src/ui/composer: `ComposerView`), their tests,
/// and `zig build composer-demo` (examples/composer_demo.zig, Linux).
fn addZeronComposer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const theme = b.modules.get("zeron_theme") orelse return;
    const model = b.modules.get("zeron_model") orelse return;
    const actions = b.modules.get("zeron_actions") orelse return;
    const engine = b.modules.get("zeron_engine") orelse return;
    const assets = b.modules.get("zeron_assets") orelse return;
    const input = b.addModule("zeron_input", .{
        .root_source_file = b.path("apps/zeron/src/ui/input/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_theme", .module = theme },
            .{ .name = "zeron_actions", .module = actions },
        },
    });
    const composer = b.addModule("zeron_composer", .{
        .root_source_file = b.path("apps/zeron/src/ui/composer/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_theme", .module = theme },
            .{ .name = "zeron_actions", .module = actions },
            .{ .name = "zeron_model", .module = model },
            .{ .name = "zeron_engine", .module = engine },
            .{ .name = "zeron_assets", .module = assets },
            .{ .name = "zeron_input", .module = input },
        },
    });
    const run_input = b.addRunArtifact(b.addTest(.{ .name = "zeron_input", .root_module = input }));
    const run_composer = b.addRunArtifact(b.addTest(.{ .name = "zeron_composer", .root_module = composer }));
    const step = b.step("composer-test", "Run the zeron editor + composer tests");
    step.dependOn(&run_input.step);
    step.dependOn(&run_composer.step);
    test_step.dependOn(step);

    if (target.result.os.tag != .linux) return;
    const exe = b.addExecutable(.{
        .name = "composer-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zeron/examples/composer_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpui", .module = zpui },
                .{ .name = "zeron_assets", .module = assets },
                .{ .name = "zeron_theme", .module = theme },
                .{ .name = "zeron_actions", .module = actions },
                .{ .name = "zeron_model", .module = model },
                .{ .name = "zeron_engine", .module = engine },
                .{ .name = "zeron_input", .module = input },
                .{ .name = "zeron_composer", .module = composer },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("composer-demo", "Run the zeron composer demo window").dependOn(&run.step);
}

/// zeron transcript + markdown UI: `zeron_ui_markdown` (apps/zeron/src/ui/markdown,
/// the reusable BlockTree → elements renderer) and `zeron_ui_transcript`
/// (apps/zeron/src/ui/transcript, `TranscriptView`), their tests, and the
/// `transcript-demo` harness (`zig build transcript-demo -- --help`).
fn addZeronTranscriptUi(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const theme = b.modules.get("zeron_theme") orelse return;
    const assets = b.modules.get("zeron_assets") orelse return;
    const markdown = b.modules.get("zeron_markdown") orelse return;
    const syntax = b.modules.get("zeron_syntax") orelse return;
    const diff = b.modules.get("zeron_diff") orelse return;
    const model = b.modules.get("zeron_model") orelse return;
    const engine = b.modules.get("zeron_engine") orelse return;
    const ui_md = b.addModule("zeron_ui_markdown", .{
        .root_source_file = b.path("apps/zeron/src/ui/markdown/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_theme", .module = theme },
            .{ .name = "zeron_assets", .module = assets },
            .{ .name = "zeron_markdown", .module = markdown },
            .{ .name = "zeron_syntax", .module = syntax },
        },
    });
    const ui_tr = b.addModule("zeron_ui_transcript", .{
        .root_source_file = b.path("apps/zeron/src/ui/transcript/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_theme", .module = theme },
            .{ .name = "zeron_assets", .module = assets },
            .{ .name = "zeron_markdown", .module = markdown },
            .{ .name = "zeron_syntax", .module = syntax },
            .{ .name = "zeron_diff", .module = diff },
            .{ .name = "zeron_model", .module = model },
            .{ .name = "zeron_engine", .module = engine },
            .{ .name = "zeron_ui_markdown", .module = ui_md },
        },
    });
    const md_tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_ui_markdown", .root_module = ui_md }));
    const tr_tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_ui_transcript", .root_module = ui_tr }));
    const ui_step = b.step("transcript-test", "Run the zeron transcript + markdown UI tests");
    ui_step.dependOn(&md_tests.step);
    ui_step.dependOn(&tr_tests.step);
    test_step.dependOn(ui_step);

    if (target.result.os.tag != .linux) return;
    const demo = b.addExecutable(.{
        .name = "transcript-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zeron/src/ui/transcript/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpui", .module = zpui },
                .{ .name = "zeron_theme", .module = theme },
                .{ .name = "zeron_assets", .module = assets },
                .{ .name = "zeron_model", .module = model },
                .{ .name = "zeron_engine", .module = engine },
                .{ .name = "zeron_ui_transcript", .module = ui_tr },
            },
        }),
    });
    b.installArtifact(demo);
    const run = b.addRunArtifact(demo);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("transcript-demo", "Render transcript fixtures in a window (apps/zeron/fixtures/transcript-*.json)").dependOn(&run.step);
}

/// The zeron desktop app (apps/zeron/src/main.zig): `zig build zeron` builds it,
/// `zig build run-zeron -- [--fixtures dir] [--frames n]` runs it. On a non-macOS
/// host targeting macOS it compiles to an object only (zig-out/zeron-mac-check.o).
fn addZeronApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const os = target.result.os.tag;
    if (os != .linux and os != .macos) return;
    const names = [_][]const u8{ "zeron_assets", "zeron_theme", "zeron_model", "zeron_engine", "zeron_actions", "zeron_markdown", "zeron_diff", "zeron_syntax", "zeron_terminal", "zeron_input", "zeron_composer", "zeron_ui_markdown", "zeron_ui_transcript" };
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "zpui", .module = zpui }) catch @panic("OOM");
    for (names) |n| if (b.modules.get(n)) |m| imports.append(b.allocator, .{ .name = n, .module = m }) catch @panic("OOM");
    const root = b.createModule(.{
        .root_source_file = b.path("apps/zeron/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports.items,
    });
    const step = b.step("zeron", "Build the zeron desktop app");
    if (os == .macos and @import("builtin").os.tag != .macos) {
        const obj = b.addObject(.{ .name = "zeron-mac-check", .root_module = root });
        const install = b.addInstallFile(obj.getEmittedBin(), "zeron-mac-check.o");
        step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
        return;
    }
    const exe = b.addExecutable(.{ .name = "zeron", .root_module = root });
    const install = b.addInstallArtifact(exe, .{});
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run-zeron", "Run the zeron desktop app").dependOn(&run.step);

    // [glass-lab] Liquid Glass lab (apps/zeron/src/glass_lab.zig): `zig build glass-lab`
    // (interactive) or `zig build glass-lab -- --smoke-frames 90 --light` (diagnostics +
    // captures to zig-out/glass-lab; ZERON_GLASS_LAB_BG=opaque|blurred|transparent).
    const lab = b.addRunArtifact(exe);
    lab.setCwd(b.path("."));
    lab.setEnvironmentVariable("ZERON_GLASS_LAB", "1");
    lab.addPassthruArgs();
    b.step("glass-lab", "Run the Liquid Glass lab window (zeron, ZERON_GLASS_LAB=1)").dependOn(&lab.step);

    // Headless shell/sidebar tests (TestPlatform + checked-in fixtures).
    const tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_app", .root_module = root, .filters = app_test_filters }));
    tests.setCwd(b.path("."));
    test_step.dependOn(&tests.step);
    b.step("zeron-app-test", "Run the zeron shell/sidebar tests").dependOn(&tests.step);
}

/// `zig build prefs-demo`: examples/prefs_demo.zig — a preferences window with every
/// native-control kind and an editable app list in the desktop's look (libadwaita /
/// Breeze drawn controls on Linux, AppKit on macOS). `ZPUI_SMOKE_FRAMES=N` renders N
/// frames, captures zig-out/prefs-demo.png and exits.
fn addPrefsDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    const os = target.result.os.tag;
    if (os != .linux and !(os == .macos and @import("builtin").os.tag == .macos)) return;
    const exe = b.addExecutable(.{
        .name = "prefs-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/prefs_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui", .module = zpui }},
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.step.dependOn(&install.step);
    run.addPassthruArgs();
    const step = b.step("prefs-demo", "Run the preferences window demo (examples/prefs_demo.zig; ZPUI_SMOKE_FRAMES=N captures zig-out/prefs-demo.png)");
    step.dependOn(&run.step);
}

/// `zig build list-demo`: examples/list_demo.zig — virtualized chat list (10k rows),
/// entrance animations, edge fade, overlay scrollbar and a frosted panel (Linux).
fn addListDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    if (target.result.os.tag != .linux) return;
    const assets = b.modules.get("zeron_assets") orelse return;
    const exe = b.addExecutable(.{
        .name = "list-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/list_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpui", .module = zpui },
                .{ .name = "zeron_assets", .module = assets },
            },
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    run.addPassthruArgs();
    const step = b.step("list-demo", "Run the virtualized list demo (examples/list_demo.zig)");
    step.dependOn(&run.step);
}

/// `zig build glyph-transform-demo`: examples/glyph_transform_demo.zig — keycap legends on a
/// sheared keyboard plane, composited vs raster-transformed glyphs side by side
/// (`ZPUI_SMOKE_FRAMES=N` writes zig-out/glyph-transform-demo.png and exits). Linux, Windows
/// (cross builds install the exe) and native macOS; cross-compiled macOS targets compile it
/// into `mac-check` instead.
fn addGlyphTransformDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
) void {
    const os = target.result.os.tag;
    if (os != .linux and os != .macos and os != .windows) return;
    const assets = b.modules.get("zeron_assets") orelse return;
    const root = b.createModule(.{
        .root_source_file = b.path("examples/glyph_transform_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_assets", .module = assets },
        },
    });
    if (os == .macos and @import("builtin").os.tag != .macos) {
        // No SDK to link against: object-only compile, part of `mac-check`.
        const obj = b.addObject(.{ .name = "glyph-transform-demo-check", .root_module = root });
        const install = b.addInstallFile(obj.getEmittedBin(), "glyph-transform-demo-check.o");
        if (b.top_level_steps.get("mac-check")) |tls| tls.step.dependOn(&install.step);
        return;
    }
    const exe = b.addExecutable(.{ .name = "glyph-transform-demo", .root_module = root });
    if (os == .windows) exe.win32_manifest = windowsManifest(b);
    const install = b.addInstallArtifact(exe, .{});
    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    const step = b.step("glyph-transform-demo", "Keycap legends on a sheared plane: composited vs raster-transformed glyphs (ZPUI_SMOKE_FRAMES=N writes zig-out/glyph-transform-demo.png)");
    // Cross-compiled Windows builds can only install the exe.
    if (os == .windows and @import("builtin").os.tag != .windows) step.dependOn(&install.step) else step.dependOn(&run.step);
}

/// zeron right-pane Changes (diff) + Git History surfaces (apps/zeron/src/ui/changes,
/// apps/zeron/src/ui/history; hosted by the shell via relative imports): their tests
/// (`zig build changes-test`) and `zig build changes-demo -- --help`, which renders the
/// reference fixtures at the reference pane position (apps/zeron/src/ui/right_pane_demo.zig).
fn addZeronRightPane(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const os = target.result.os.tag;
    const names = [_][]const u8{ "zeron_assets", "zeron_theme", "zeron_model", "zeron_engine", "zeron_actions", "zeron_markdown", "zeron_diff", "zeron_syntax", "zeron_input", "zeron_ui_markdown" };
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "zpui", .module = zpui }) catch @panic("OOM");
    for (names) |n| {
        const m = b.modules.get(n) orelse return;
        imports.append(b.allocator, .{ .name = n, .module = m }) catch @panic("OOM");
    }
    const root = b.createModule(.{
        .root_source_file = b.path("apps/zeron/src/ui/right_pane_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports.items,
    });
    const tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_right_pane", .root_module = root }));
    tests.setCwd(b.path("."));
    b.step("changes-test", "Run the zeron Changes/History pane tests").dependOn(&tests.step);
    test_step.dependOn(&tests.step);
    if (os != .linux) return;
    const exe = b.addExecutable(.{ .name = "changes-demo", .root_module = root });
    const install = b.addInstallArtifact(exe, .{});
    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("changes-demo", "Render the right-pane Changes/History surfaces from fixtures").dependOn(&run.step);
}

/// zeron packaging (after `addZeronApp`, whose `zeron` step installs the binary):
///   `zig build zeron-app-bundle [-Dtarget=aarch64-macos|x86_64-macos]` → zig-out/Zeron.app
///     (apps/zeron/scripts/macos-bundle.sh; macOS hosts only — linking needs the SDK).
///     Run it for both arches to get a universal (lipo) binary in the bundle.
///   `zig build zeron-dist` (Linux) → zig-out/zeron-<version>-linux-<arch>.tar.gz
///     (apps/zeron/scripts/linux-dist.sh: binary + desktop entry + icon + licenses).
/// `-Dzeron-version=` sets the bundle/tarball version (default: the Rust app's).
/// `-Dzeron-src=<zeron checkout>` (or env ZERON_SRC / ZERON_ENGINE) bundles the engine
/// (`zeron-engine`, apps/zeron/engine-host via apps/zeron/scripts/build-engine.sh) so the
/// app needs no Rust Zeron install; pass the commit tools/upstream/map.json pins.
fn addZeronPackaging(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const os = target.result.os.tag;
    if (os != .linux and os != .macos) return;
    const zeron_step = b.top_level_steps.get("zeron") orelse return;
    const version = b.option([]const u8, "zeron-version", "Version for Zeron.app / the Linux tarball (default 0.2.102)") orelse "0.2.102";
    const arch = @tagName(target.result.cpu.arch);
    const script, const name, const desc = if (os == .macos)
        .{ "apps/zeron/scripts/macos-bundle.sh", "zeron-app-bundle", "Assemble zig-out/Zeron.app (macOS host; build both arches for a universal binary)" }
    else
        .{ "apps/zeron/scripts/linux-dist.sh", "zeron-dist", "Package zig-out/zeron-<version>-linux-<arch>.tar.gz" };
    const run = b.addSystemCommand(&.{"bash"});
    run.addFileArg(b.path(script));
    run.addDirectoryArg(b.path("."));
    run.addDirectoryArg(b.graph.path(.install_prefix, ""));
    run.addArgs(&.{ arch, version });
    run.has_side_effects = true;
    if (b.option([]const u8, "zeron-src", "zeron checkout to build the bundled engine from (default: env ZERON_SRC)")) |src|
        run.setEnvironmentVariable("ZERON_SRC", src);
    run.step.dependOn(&zeron_step.step);
    b.step(name, desc).dependOn(&run.step);
}

/// zeron Files explorer + file editor (apps/zeron/src/ui/files, apps/zeron/src/ui/editor;
/// hosted by the shell via relative imports): their tests (`zig build files-test`) and
/// `zig build files-demo -- --help` (apps/zeron/src/ui/files_demo.zig), which renders the
/// explorer and editor over `apps/zeron/fixtures/files` at the reference pane positions.
fn addZeronFiles(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const os = target.result.os.tag;
    const names = [_][]const u8{ "zeron_assets", "zeron_theme", "zeron_model", "zeron_engine", "zeron_actions", "zeron_markdown", "zeron_diff", "zeron_syntax", "zeron_input", "zeron_ui_markdown" };
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "zpui", .module = zpui }) catch @panic("OOM");
    for (names) |n| {
        const m = b.modules.get(n) orelse return;
        imports.append(b.allocator, .{ .name = n, .module = m }) catch @panic("OOM");
    }
    const root = b.createModule(.{
        .root_source_file = b.path("apps/zeron/src/ui/files_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports.items,
    });
    const tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_files", .root_module = root }));
    tests.setCwd(b.path("."));
    b.step("files-test", "Run the zeron Files explorer / file editor tests").dependOn(&tests.step);
    test_step.dependOn(&tests.step);
    if (os != .linux) return;
    const exe = b.addExecutable(.{ .name = "files-demo", .root_module = root });
    const install = b.addInstallArtifact(exe, .{});
    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("files-demo", "Render the zeron Files explorer and file editor from fixtures").dependOn(&run.step);
}

/// zeron's Linux browser helper (apps/zeron/native/linux-browser/helper.c, zeron's
/// WebKitGTK offscreen renderer, copied verbatim): compiled with `zig cc` into
/// zig-out/bin/zeron-webkit, next to `zeron`, and installed by `zig build zeron` /
/// `run-zeron` / `install`. Optional: skipped (with a note) when pkg-config cannot find
/// webkit2gtk-4.1 + json-glib-1.0, or when cross-compiling; zeron then reports the
/// missing helper in the Browser tab. `zig build zeron-webkit` builds only the helper.
fn addZeronBrowserHelper(b: *std.Build, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .linux or !target.query.isNative()) return;
    const libs = [_][]const u8{ "webkit2gtk-4.1", "json-glib-1.0" };
    const found = switch (b.runFallible(&.{ "pkg-config", "--exists", libs[0], libs[1] }, .{ .stderr_behavior = .ignore })) {
        .success => true,
        else => false,
    };
    const step = b.step("zeron-webkit", "Build the Linux browser helper (needs webkit2gtk-4.1 + json-glib-1.0 dev files)");
    if (!found) {
        const note = b.addFail("zeron-webkit: pkg-config cannot find webkit2gtk-4.1 and json-glib-1.0 (install libwebkit2gtk-4.1-dev libjson-glib-dev)");
        step.dependOn(&note.step);
        return;
    }
    const helper = b.addExecutable(.{
        .name = "zeron-webkit",
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
    });
    helper.root_module.addCSourceFile(.{
        .file = b.path("apps/zeron/native/linux-browser/helper.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-parameter" },
    });
    // Zig's own pkg-config handling rejects webkit2gtk's `-Wl,--export-dynamic`;
    // translate the flags here (-I, -L, -l; linker-only flags are not needed).
    const flags = switch (b.runFallible(&.{ "pkg-config", "--cflags", "--libs", libs[0], libs[1] }, .{})) {
        .success => |out| out,
        else => return,
    };
    var it = std.mem.tokenizeAny(u8, flags, " \t\r\n");
    while (it.next()) |f| {
        if (std.mem.startsWith(u8, f, "-I")) {
            helper.root_module.addSystemIncludePath(.{ .cwd_relative = f[2..] });
        } else if (std.mem.startsWith(u8, f, "-L")) {
            helper.root_module.addLibraryPath(.{ .cwd_relative = f[2..] });
        } else if (std.mem.startsWith(u8, f, "-l")) {
            helper.root_module.linkSystemLibrary(f[2..], .{ .use_pkg_config = .no });
        } else if (std.mem.startsWith(u8, f, "-D")) {
            const eq = std.mem.indexOfScalar(u8, f, '=');
            helper.root_module.addCMacro(f[2 .. eq orelse f.len], if (eq) |e| f[e + 1 ..] else "1");
        }
    }
    const install = b.addInstallArtifact(helper, .{});
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
    if (b.top_level_steps.get("zeron")) |tl| tl.step.dependOn(&install.step);
    // `run-zeron` runs the binary: the helper must be installed before it starts.
    if (b.top_level_steps.get("run-zeron")) |tl| for (tl.step.dependencies.items) |dep| dep.dependOn(&install.step);
}

/// zeron media: `zeron_mermaid` (apps/zeron/src/mermaid, a Zig port of
/// mermaid-rs-renderer 0.3.1: parser, layout, SVG emission + zeron's palette
/// and restyle) and `zeron_media` (apps/zeron/src/ui/media: the image
/// lightbox and attachment widgets). Both are wired into the composer,
/// transcript and markdown modules created earlier. `zig build mermaid-test`
/// runs the renderer's parity tests; `zig build media-test` the UI ones.
fn addZeronMedia(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const theme = b.modules.get("zeron_theme") orelse return;
    const model = b.modules.get("zeron_model") orelse return;
    const assets = b.modules.get("zeron_assets") orelse return;
    const mermaid = b.addModule("zeron_mermaid", .{
        .root_source_file = b.path("apps/zeron/src/mermaid/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const media = b.addModule("zeron_media", .{
        .root_source_file = b.path("apps/zeron/src/ui/media/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "zeron_theme", .module = theme },
            .{ .name = "zeron_model", .module = model },
            .{ .name = "zeron_assets", .module = assets },
            .{ .name = "zeron_mermaid", .module = mermaid },
        },
    });
    for ([_][]const u8{ "zeron_composer", "zeron_ui_transcript", "zeron_ui_markdown" }) |name| {
        const m = b.modules.get(name) orelse continue;
        m.addImport("zeron_media", media);
        m.addImport("zeron_mermaid", mermaid);
    }
    const mermaid_tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_mermaid", .root_module = mermaid }));
    mermaid_tests.setCwd(b.path("."));
    b.step("mermaid-test", "Run the zeron Mermaid renderer tests (parity with mermaid-rs-renderer)").dependOn(&mermaid_tests.step);
    const media_tests = b.addRunArtifact(b.addTest(.{ .name = "zeron_media", .root_module = media }));
    b.step("media-test", "Run the zeron media UI tests (lightbox geometry, widgets)").dependOn(&media_tests.step);
    test_step.dependOn(&mermaid_tests.step);
    test_step.dependOn(&media_tests.step);

    // `zig build mermaid-visual -- <ref_png_dir> <out_dir>`: raster parity
    // against resvg renders of the Rust pipeline's SVG (pixel diff report).
    const visual = b.addExecutable(.{
        .name = "mermaid-visual",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zeron/scripts/mermaid_visual.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpui", .module = zpui },
                .{ .name = "zeron_media", .module = media },
                .{ .name = "zeron_mermaid", .module = mermaid },
            },
        }),
    });
    const run_visual = b.addRunArtifact(visual);
    run_visual.setCwd(b.path("."));
    run_visual.addPassthruArgs();
    b.step("mermaid-visual", "Pixel-diff zeron Mermaid rasters against reference PNGs").dependOn(&run_visual.step);
}

/// zeron app lifecycle support (apps/zeron/src/lifecycle): adds two imports to the app's
/// root module (apps/zeron/src/main.zig, shared by `zeron`, `run-zeron`, the macOS check
/// object and `zeron-app-test`):
///   `zeron_build`  — `version` (the `-Dzeron-version=` packaging option, default
///                    0.2.102; `zeron --version` and the self-updater use it) and
///                    `releases_url` (`-Dzeron-releases-url=`, the default update feed;
///                    empty = updates off unless `ZERON_RELEASES_URL` is set);
///   `zeron_sounds` — the embedded chimes from apps/zeron/assets/sounds.
fn addZeronLifecycle(b: *std.Build) void {
    const zeron_step = b.top_level_steps.get("zeron") orelse return;
    const root = findRootModule(&zeron_step.step, "apps/zeron/src/main.zig") orelse return;
    const version = if (b.user_input_options.get("zeron-version")) |opt| switch (opt) {
        .scalar => |s| s,
        else => "0.2.102",
    } else "0.2.102";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "releases_url", b.option([]const u8, "zeron-releases-url", "Default self-update feed of the zeron app (empty: off unless ZERON_RELEASES_URL is set)") orelse "");
    root.addImport("zeron_build", options.createModule());

    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("apps/zeron/assets/sounds"), "sounds", .{ .include_extensions = &.{".wav"} });
    const sounds = b.createModule(.{ .root_source_file = files.add("sounds.zig",
        \\//! zeron's session chimes (apps/zeron/assets/sounds, MIT — zeron's own cues).
        \\pub const done = @embedFile("sounds/done.wav");
        \\pub const request = @embedFile("sounds/request.wav");
        \\pub const attention = @embedFile("sounds/attention.wav");
        \\pub const appshot = @embedFile("sounds/appshot.wav");
        \\
    ) });
    root.addImport("zeron_sounds", sounds);
}

/// The root module of the first compile step (depth-first under `step`) whose root
/// source file is `path`.
fn findRootModule(step: *std.Build.Step, path: []const u8) ?*std.Build.Module {
    if (step.cast(std.Build.Step.Compile)) |compile| {
        if (compile.root_module.root_source_file) |src| switch (src) {
            .src_path => |sp| if (std.mem.eql(u8, sp.sub_path, path)) return compile.root_module,
            else => {},
        };
    }
    for (step.dependencies.items) |dep| if (findRootModule(dep, path)) |m| return m;
    return null;
}

/// zpui.audio (src/audio/): low-latency sound-effect playback, also exported
/// as the standalone `zpui_audio` module (no GPU/windowing dependencies).
/// `zig build audio-test` runs its tests (null backend, offline rendering),
/// `zig build audio-demo` plays a synthesized click pattern on the default
/// output (`ZPUI_AUDIO_OFFLINE=out.wav` renders it to a file instead), and
/// `audio-check` compiles the demo for the selected target: an object file
/// (zig-out/audio-check.o) when targeting macOS from another host (no SDK),
/// a linked executable otherwise.
fn addAudio(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const os = target.result.os.tag;
    const host_os = @import("builtin").os.tag;
    const mac_cross = os == .macos and host_os != .macos;
    const audio = b.addModule("zpui_audio", .{
        .root_source_file = b.path("src/audio/audio.zig"),
        .target = target,
        .optimize = optimize,
        // Linux backends are dlopen'ed; macOS uses libdispatch + AudioToolbox.
        .link_libc = os != .windows,
    });
    if (os == .macos and !mac_cross) {
        for ([_]*std.Build.Module{ audio, zpui }) |m| {
            m.linkFramework("AudioToolbox", .{});
            m.linkFramework("CoreAudio", .{});
            m.linkFramework("CoreFoundation", .{});
        }
    }

    const tests = b.addTest(.{ .name = "zpui_audio", .root_module = audio });
    const run_tests = b.addRunArtifact(tests);
    b.step("audio-test", "Run the zpui.audio tests (null backend, offline rendering)").dependOn(&run_tests.step);
    if (!mac_cross) test_step.dependOn(&run_tests.step);

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/audio_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zpui_audio", .module = audio }},
    });
    if (mac_cross) {
        const check_mod = b.createModule(.{
            .root_source_file = b.path("examples/audio_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpui_audio", .module = audio }},
        });
        const obj = b.addObject(.{ .name = "audio-check", .root_module = check_mod });
        const install = b.addInstallFile(obj.getEmittedBin(), "audio-check.o");
        b.step("audio-check", "Compile zpui.audio + demo for -Dtarget (object only when cross-compiling to macOS)").dependOn(&install.step);
        return;
    }
    const demo = b.addExecutable(.{ .name = "audio-demo", .root_module = demo_mod });
    const install_demo = b.addInstallArtifact(demo, .{});
    b.step("audio-check", "Compile zpui.audio + demo for -Dtarget (object only when cross-compiling to macOS)").dependOn(&install_demo.step);
    const run = b.addRunArtifact(demo);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("audio-demo", "Play a synthesized keyboard-click pattern (ZPUI_AUDIO_OFFLINE=out.wav renders to a WAV file)").dependOn(&run.step);
}
