#version 450
#include "underline.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_color;
layout(location = 0) out vec4 out_color;

// Port of Metal `underline_fragment` (M:128).
void main() {
  const float WAVE_FREQUENCY = 2.0;
  const float WAVE_HEIGHT_RATIO = 0.8;
  Underline u = pc.instances.items[v_id];
  if (u.wavy != 0u) {
    float half_thickness = u.thickness * 0.5;
    float h = u.bounds.size.y;
    vec2 st = ((gl_FragCoord.xy - u.bounds.origin) / h) - vec2(0.0, 0.5);
    float frequency = (M_PI_F * WAVE_FREQUENCY * u.thickness) / h;
    float amplitude = (u.thickness * WAVE_HEIGHT_RATIO) / h;
    float sine = sin(st.x * frequency) * amplitude;
    float dsine = cos(st.x * frequency) * amplitude * frequency;
    float distance = (st.y - sine) / sqrt(1.0 + dsine * dsine);
    float distance_in_pixels = distance * h;
    float distance_from_top_border = distance_in_pixels - half_thickness;
    float distance_from_bottom_border = distance_in_pixels + half_thickness;
    float alpha = clamp(0.5 - max(-distance_from_bottom_border, distance_from_top_border), 0.0, 1.0);
    out_color = v_color * vec4(1.0, 1.0, 1.0, alpha);
  } else {
    out_color = v_color;
  }
}
