#include "common.glsl"
struct ImageAlphaMaskParams {
  Bounds bounds;
  float radius;
  float feather;
  float clearance;
  float bottom_y;
  float bottom_feather;
  float pad;
};
struct PolychromeSprite {
  uint order;
  uint pad;
  uint grayscale;
  float opacity;
  Bounds bounds;
  Bounds content_mask;
  Corners corner_radii;
  EdgeFadeParams fade;
  ImageAlphaMaskParams alpha_mask;
  AtlasTile tile;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer PolychromeSprites { PolychromeSprite items[]; };
PUSH_CONSTANTS(PolychromeSprites)
layout(set = 0, binding = 0) uniform sampler2D atlas_texture;
