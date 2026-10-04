/* C ABI of zpui's image backends (src/image/c.zig declares the same functions
 * as Zig externs). Implemented by zpui_svg.cpp (lunasvg) and zpui_decode.c
 * (stb_image + simplewebp). Every function is reentrant: distinct handles and
 * buffers may be used from different threads concurrently. */
#ifndef ZPUI_IMAGE_C_H
#define ZPUI_IMAGE_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- SVG (lunasvg) ---- */
typedef struct zpui_svg zpui_svg;

/* Parse an SVG document; NULL on malformed input. */
zpui_svg* zpui_svg_parse(const char* data, size_t len);
void zpui_svg_destroy(zpui_svg* svg);
/* Intrinsic size (width/height attributes, else the viewBox size). */
void zpui_svg_size(const zpui_svg* svg, float* width, float* height);
/* Render into `pixels` (premultiplied ARGB32 in native endianness, i.e. BGRA
 * bytes on little-endian, stride in bytes, cleared by the caller) with the
 * user->device matrix (a b c d e f). `current_color` is 0xAARRGGBB and is the
 * value of `currentColor` at the root. Returns 0 on success. */
int zpui_svg_render(zpui_svg* svg, uint8_t* pixels, int width, int height, int stride,
                    const float matrix[6], uint32_t current_color);

/* ---- Raster decoding (stb_image, simplewebp) ---- */

/* Header probe: dimensions without decoding. Returns 1 on success. */
int zpui_stbi_info(const uint8_t* data, int len, int* width, int* height);
/* Decode the first image/frame to RGBA8 (straight alpha). Free with zpui_decode_free. */
uint8_t* zpui_stbi_load_rgba(const uint8_t* data, int len, int* width, int* height);
/* Decode every GIF frame (composited, RGBA8, width*height*4 bytes each,
 * consecutive) plus per-frame delays in ms (*delays, free with zpui_decode_free). */
uint8_t* zpui_stbi_load_gif(const uint8_t* data, int len, int** delays, int* width, int* height, int* frames);
/* Reason for the last stb_image failure on this thread. */
const char* zpui_stbi_failure_reason(void);
/* Decode a WebP (lossy/lossless, first frame) to RGBA8. Free with zpui_decode_free. */
uint8_t* zpui_webp_load_rgba(const uint8_t* data, size_t len, int* width, int* height);
void zpui_decode_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif
