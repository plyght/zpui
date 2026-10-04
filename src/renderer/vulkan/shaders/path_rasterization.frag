#version 450
#include "path.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) in vec2 v_st;
layout(location = 0) out vec4 out_color;

// Port of Metal `path_rasterization_fragment` (M:327): Loop-Blinn quadratic
// coverage, premultiplied output into the (MSAA) intermediate texture.
void main() {
  vec2 dx = dFdx(v_st);
  vec2 dy = dFdy(v_st);
  PathRasterizationVertex v = pc.instances.items[v_id];
  float alpha;
  if (length(vec2(dx.x, dy.x)) < 0.001) {
    alpha = 1.0;
  } else {
    vec2 gradient = vec2((2.0 * v_st.x) * dx.x - dx.y, (2.0 * v_st.x) * dy.x - dy.y);
    float f = (v_st.x * v_st.x) - v_st.y;
    float distance = f / length(gradient);
    alpha = clamp(0.5 - distance, 0.0, 1.0);
  }
  GradientColor g = prepare_fill_color(v.color);
  vec4 color = fill_color(v.color, gl_FragCoord.xy, v.bounds, g.solid, g.color0, g.color1);
  out_color = vec4(color.rgb * color.a * alpha, alpha * color.a);
}
