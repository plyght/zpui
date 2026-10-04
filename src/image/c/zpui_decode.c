/* stb_image + simplewebp behind zpui's C ABI (see zpui_image_c.h). */
#include "zpui_image_c.h"

#include <stdlib.h>

#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
/* Raster formats gpui's `image` features cover that stb decodes. */
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_ONLY_TGA
#define STBI_ONLY_HDR
#define STBI_ONLY_PNM
/* zpui caps decode sizes itself; this is stb's hard per-axis limit. */
#define STBI_MAX_DIMENSIONS (1 << 15)
#include "stb_image.h"

#define SIMPLEWEBP_IMPLEMENTATION
#define SIMPLEWEBP_DISABLE_STDIO
#include "simplewebp.h"

int zpui_stbi_info(const uint8_t* data, int len, int* width, int* height)
{
    int comp = 0;
    return stbi_info_from_memory(data, len, width, height, &comp);
}

uint8_t* zpui_stbi_load_rgba(const uint8_t* data, int len, int* width, int* height)
{
    int comp = 0;
    return stbi_load_from_memory(data, len, width, height, &comp, 4);
}

uint8_t* zpui_stbi_load_gif(const uint8_t* data, int len, int** delays, int* width, int* height, int* frames)
{
    int comp = 0;
    *delays = NULL;
    return stbi_load_gif_from_memory(data, len, delays, width, height, frames, &comp, 4);
}

const char* zpui_stbi_failure_reason(void)
{
    const char* reason = stbi_failure_reason();
    return reason ? reason : "unknown";
}

uint8_t* zpui_webp_load_rgba(const uint8_t* data, size_t len, int* width, int* height)
{
    simplewebp* webp = NULL;
    if (simplewebp_load_from_memory((void*)data, len, NULL, &webp) != SIMPLEWEBP_NO_ERROR)
        return NULL;
    size_t w = 0, h = 0;
    simplewebp_get_dimensions(webp, &w, &h);
    if (w == 0 || h == 0 || w > (1u << 14) || h > (1u << 14)) {
        simplewebp_unload(webp);
        return NULL;
    }
    uint8_t* pixels = (uint8_t*)malloc(w * h * 4);
    if (pixels && simplewebp_decode(webp, pixels, NULL) != SIMPLEWEBP_NO_ERROR) {
        free(pixels);
        pixels = NULL;
    }
    simplewebp_unload(webp);
    *width = (int)w;
    *height = (int)h;
    return pixels;
}

void zpui_decode_free(void* ptr)
{
    free(ptr);
}
