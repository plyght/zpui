#include "common.glsl"
struct Underline {
  uint order;
  uint pad;
  Bounds bounds;
  Bounds content_mask;
  Hsla color;
  float thickness;
  uint wavy;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Underlines { Underline items[]; };
PUSH_CONSTANTS(Underlines)
