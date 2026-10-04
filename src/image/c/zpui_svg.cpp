// lunasvg behind zpui's C ABI (see zpui_image_c.h). C++ exceptions never
// cross the boundary.
#include "zpui_image_c.h"

#include <lunasvg.h>

#include <cstdio>
#include <memory>
#include <new>
#include <string>

struct zpui_svg {
    std::unique_ptr<lunasvg::Document> document;
    uint32_t current_color = 0xFF000000u;
};

static void set_current_color(zpui_svg* svg, uint32_t argb)
{
    if (svg->current_color == argb)
        return;
    svg->current_color = argb;
    char value[40];
    std::snprintf(value, sizeof value, "rgba(%u,%u,%u,%.4f)", (argb >> 16) & 0xFFu, (argb >> 8) & 0xFFu,
                  argb & 0xFFu, ((argb >> 24) & 0xFFu) / 255.0);
    // `color` inherits, so setting it on the root defines `currentColor`.
    svg->document->documentElement().setAttribute("color", value);
}

extern "C" zpui_svg* zpui_svg_parse(const char* data, size_t len)
{
    try {
        auto document = lunasvg::Document::loadFromData(data, len);
        if (!document)
            return nullptr;
        auto* svg = new zpui_svg;
        svg->document = std::move(document);
        return svg;
    } catch (...) {
        return nullptr;
    }
}

extern "C" void zpui_svg_destroy(zpui_svg* svg)
{
    delete svg;
}

extern "C" void zpui_svg_size(const zpui_svg* svg, float* width, float* height)
{
    *width = svg->document->width();
    *height = svg->document->height();
}

extern "C" int zpui_svg_render(zpui_svg* svg, uint8_t* pixels, int width, int height, int stride,
                               const float m[6], uint32_t current_color)
{
    try {
        set_current_color(svg, current_color);
        lunasvg::Bitmap bitmap(pixels, width, height, stride);
        if (bitmap.isNull())
            return 1;
        svg->document->render(bitmap, lunasvg::Matrix(m[0], m[1], m[2], m[3], m[4], m[5]));
        return 0;
    } catch (...) {
        return 2;
    }
}
