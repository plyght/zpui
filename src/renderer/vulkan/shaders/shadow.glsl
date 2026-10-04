#include "common.glsl"
struct Shadow {
  uint order;
  float blur_radius;
  Bounds bounds;
  Corners corner_radii;
  Bounds content_mask;
  Hsla color;
  Bounds element_bounds;
  Corners element_corner_radii;
  uint inset;
  uint pad;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Shadows { Shadow items[]; };
PUSH_CONSTANTS(Shadows)
