#version 450
// zpui.three: viewport composite in the UI pass. p0 = bounds (x, y, w, h,
// device px), p1 = content mask, p2 = corner radii (tl, tr, br, bl), p3 = (viewport w, h, opacity).
#include "post.glsl"

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec2 v_pos;

const vec2 UNIT[6] = vec2[6](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

void main() {
  vec2 u = UNIT[gl_VertexIndex];
  vec2 p = P.p0.xy + u * P.p0.zw;
  v_uv = u;
  v_pos = p;
  gl_Position = vec4(p / P.p3.xy * 2.0 - 1.0, 0.0, 1.0);
}
