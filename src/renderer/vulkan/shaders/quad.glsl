// Quad instance declarations shared by quad.vert / quad.frag.
#include "common.glsl"

struct Quad {
  uint order;
  uint border_style;
  Bounds bounds;
  Bounds content_mask;
  Background background;
  Hsla border_color;
  Corners corner_radii;
  Edges border_widths;
  EdgeFadeParams fade;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Quads { Quad items[]; };
PUSH_CONSTANTS(Quads)
