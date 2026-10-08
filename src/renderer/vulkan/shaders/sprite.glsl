// Monochrome and subpixel sprites share one instance layout.
#include "common.glsl"
struct MonochromeSprite {
  uint order;
  uint pad;
  Bounds bounds;
  Bounds content_mask;
  Hsla color;
  AtlasTile tile;
  TransformationMatrix transformation;
  EdgeFadeParams fade;
  float blur;  // gaussian sigma in device px (monochrome only; 0 = crisp)
  float pad2;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer MonochromeSprites { MonochromeSprite items[]; };
PUSH_CONSTANTS(MonochromeSprites)
layout(set = 0, binding = 0) uniform sampler2D atlas_texture;
