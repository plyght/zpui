/* stb_image + simplewebp behind zpui's C ABI (see zpui_image_c.h). */
#include "zpui_image_c.h"

#include <stdlib.h>
#include <string.h>

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

/* ---- streaming GIF (stbi__load_gif_main, one frame per call) ---- */

struct zpui_gif_stream {
    stbi__context ctx;
    stbi__gif g;
    const uint8_t* data;
    int len;
    int frames;
    size_t stride;
    uint8_t* last;     /* output of frame n-1 */
    uint8_t* two_back; /* output of frame n-2 (dispose-to-previous) */
};

static void zpui_gif_stream_reset(zpui_gif_stream* s)
{
    STBI_FREE(s->g.out);
    STBI_FREE(s->g.history);
    STBI_FREE(s->g.background);
    memset(&s->g, 0, sizeof(s->g));
    stbi__start_mem(&s->ctx, s->data, s->len);
    s->frames = 0;
}

zpui_gif_stream* zpui_gif_stream_open(const uint8_t* data, int len)
{
    zpui_gif_stream* s = (zpui_gif_stream*)calloc(1, sizeof(zpui_gif_stream));
    if (!s) return NULL;
    s->data = data;
    s->len = len;
    stbi__start_mem(&s->ctx, data, len);
    if (!stbi__gif_test(&s->ctx)) {
        free(s);
        return NULL;
    }
    stbi__start_mem(&s->ctx, data, len);
    return s;
}

const uint8_t* zpui_gif_stream_next(zpui_gif_stream* s, int* width, int* height, int* delay_ms, int* done)
{
    int comp = 0;
    stbi_uc* u;
    *done = 0;
    u = stbi__gif_load_next(&s->ctx, &s->g, &comp, 4, s->frames >= 2 ? s->two_back : NULL);
    if (u == (stbi_uc*)&s->ctx) {
        *done = 1;
        return NULL;
    }
    if (!u) return NULL;
    if (!s->last) {
        s->stride = (size_t)s->g.w * (size_t)s->g.h * 4;
        s->last = (uint8_t*)malloc(s->stride);
        s->two_back = (uint8_t*)malloc(s->stride);
        if (!s->last || !s->two_back) return NULL;
    }
    {
        uint8_t* t = s->two_back;
        s->two_back = s->last;
        s->last = t;
        memcpy(s->last, u, s->stride);
    }
    s->frames++;
    *width = s->g.w;
    *height = s->g.h;
    *delay_ms = s->g.delay;
    return u;
}

void zpui_gif_stream_rewind(zpui_gif_stream* s)
{
    zpui_gif_stream_reset(s);
}

void zpui_gif_stream_close(zpui_gif_stream* s)
{
    if (!s) return;
    STBI_FREE(s->g.out);
    STBI_FREE(s->g.history);
    STBI_FREE(s->g.background);
    free(s->last);
    free(s->two_back);
    free(s);
}
