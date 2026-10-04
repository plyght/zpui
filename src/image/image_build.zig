//! Build helper for src/image/, imported by the repo's build.zig: compiles the
//! vendored image backends into the `zpui` module.
//!
//! - lunasvg (C++17) + its bundled plutovg (C): SVG parsing and rasterization
//!   (vendor/lunasvg, vendor/plutovg; MIT, plutovg's FreeType-derived raster
//!   under the FTL);
//! - stb_image (C): PNG/JPEG/GIF/BMP/TGA/HDR/PNM decoding (vendor/stb);
//! - simplewebp (C): WebP decoding (vendor/simplewebp; BSD-3-Clause).
//!
//! The C ABI is src/image/c/zpui_image_c.h; src/image/c.zig declares it as
//! Zig externs, so no translate-c step is needed. lunasvg needs libc++, which
//! Zig ships for every target (including cross builds to macOS).

const std = @import("std");

const lunasvg_sources = [_][]const u8{
    "vendor/lunasvg/source/graphics.cpp",
    "vendor/lunasvg/source/lunasvg.cpp",
    "vendor/lunasvg/source/svgelement.cpp",
    "vendor/lunasvg/source/svggeometryelement.cpp",
    "vendor/lunasvg/source/svglayoutstate.cpp",
    "vendor/lunasvg/source/svgpaintelement.cpp",
    "vendor/lunasvg/source/svgparser.cpp",
    "vendor/lunasvg/source/svgproperty.cpp",
    "vendor/lunasvg/source/svgrenderstate.cpp",
    "vendor/lunasvg/source/svgtextelement.cpp",
    "src/image/c/zpui_svg.cpp",
};

const plutovg_sources = [_][]const u8{
    "vendor/plutovg/source/plutovg-blend.c",
    "vendor/plutovg/source/plutovg-canvas.c",
    "vendor/plutovg/source/plutovg-font.c",
    "vendor/plutovg/source/plutovg-ft-math.c",
    "vendor/plutovg/source/plutovg-ft-raster.c",
    "vendor/plutovg/source/plutovg-ft-stroker.c",
    "vendor/plutovg/source/plutovg-matrix.c",
    "vendor/plutovg/source/plutovg-paint.c",
    "vendor/plutovg/source/plutovg-path.c",
    "vendor/plutovg/source/plutovg-rasterize.c",
    "vendor/plutovg/source/plutovg-surface.c",
};

/// Add the image backends to `module` (the `zpui` module).
pub fn add(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.link_libcpp = true;
    for ([_][]const u8{ "vendor/lunasvg/include", "vendor/plutovg/include", "vendor/stb", "vendor/simplewebp", "src/image/c" }) |dir|
        module.addIncludePath(b.path(dir));
    // Vendored third-party code: keep it warning-quiet and out of UBSan's
    // trap mode (stb/FreeType-style code relies on benign shifts/overflow).
    const common = [_][]const u8{ "-DLUNASVG_BUILD_STATIC", "-DPLUTOVG_BUILD_STATIC", "-fno-sanitize=undefined", "-w" };
    module.addCSourceFiles(.{ .files = &lunasvg_sources, .flags = &(common ++ [_][]const u8{"-std=c++17"}) });
    module.addCSourceFiles(.{ .files = &plutovg_sources, .flags = &common });
    module.addCSourceFiles(.{ .files = &.{"src/image/c/zpui_decode.c"}, .flags = &common });
}
