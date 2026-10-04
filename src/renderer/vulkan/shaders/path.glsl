#include "common.glsl"
struct PathRasterizationVertex {
  vec2 xy_position;
  vec2 st_position;
  Background color;
  Bounds bounds;
};
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer PathVertices { PathRasterizationVertex items[]; };
PUSH_CONSTANTS(PathVertices)
