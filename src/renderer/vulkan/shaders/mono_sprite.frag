#version 450
#include "sprite.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_color;
layout(location = 2) in vec2 v_tile_position;
layout(location = 0) out vec4 out_color;

// Port of Metal `monochrome_sprite_fragment` (M:199). The atlas is R8 here (A8 on Metal).
// Blurred sprites (zui 0966d06) gaussian-tap the tile like Metal / WGSL `fs_mono_sprite`.
void main() {
  MonochromeSprite sprite = pc.instances.items[v_id];
  float coverage;
  if (sprite.blur > 0.0) {
    // Gaussian taps around the texel; taps outside the tile read as transparent, in-tile taps
    // clamp half a texel in so linear filtering never bleeds a neighboring glyph.
    float sigma = sprite.blur;
    vec2 atlas_dims = pc.texture_size;
    vec2 texel = 1.0 / atlas_dims;
    vec2 tile_min = vec2(sprite.tile.origin) / atlas_dims;
    vec2 tile_max = tile_min + vec2(sprite.tile.size) / atlas_dims;
    vec2 tile_mid = 0.5 * (tile_min + tile_max);
    vec2 inset_min = min(tile_min + 0.5 * texel, tile_mid);
    vec2 inset_max = max(tile_max - 0.5 * texel, tile_mid);
    int radius = min(int(ceil(3.0 * sigma)), 12);
    float accum = 0.0;
    float total = 0.0;
    for (int y = -radius; y <= radius; y++) {
      for (int x = -radius; x <= radius; x++) {
        vec2 offset = vec2(x, y);
        float weight = exp(-dot(offset, offset) / (2.0 * sigma * sigma));
        vec2 uv = v_tile_position + offset * texel;
        float tap = 0.0;
        if (all(greaterThanEqual(uv, tile_min)) && all(lessThanEqual(uv, tile_max))) {
          tap = textureLod(atlas_texture, clamp(uv, inset_min, inset_max), 0.0).r;
        }
        accum += weight * tap;
        total += weight;
      }
    }
    coverage = accum / max(total, 1e-6);
  } else {
    coverage = texture(atlas_texture, v_tile_position).r;
  }
  vec4 color = v_color;
  color.a *= coverage * edge_fade_alpha(gl_FragCoord.xy, sprite.fade);
  out_color = color;
}
