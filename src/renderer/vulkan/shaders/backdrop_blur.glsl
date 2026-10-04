#include "common.glsl"
struct BackdropBlur {
  uint order;
  float blur_radius;
  Bounds bounds;
  Bounds content_mask;
  Corners corner_radii;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer BackdropBlurs { BackdropBlur items[]; };
PUSH_CONSTANTS(BackdropBlurs)
layout(set = 0, binding = 0) uniform sampler2D blurred_texture;
