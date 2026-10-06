#version 450
#include "three_common.glsl"
layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_normal;
layout(location = 0) out vec4 out_color;

const float PI = 3.14159265;

// glTF metallic-roughness BRDF: GGX NDF, Smith-Schlick-GGX visibility, Schlick Fresnel.
float d_ggx(float n_h, float a) {
  float a2 = a * a;
  float d = n_h * n_h * (a2 - 1.0) + 1.0;
  return a2 / (PI * d * d);
}
float v_smith(float n_v, float n_l, float a) {
  float k = a * 0.5;
  return 0.25 / ((n_v * (1.0 - k) + k) * (n_l * (1.0 - k) + k));
}

void main() {
  FrameUniforms f = pc.frame.f;
  DrawData d = pc.draw.d;
  vec3 n = normalize(v_normal);
  vec3 v = normalize(f.camera_pos.xyz - v_world);
  vec3 l = normalize(f.light_dir.xyz);
  vec3 h = normalize(v + l);
  float n_l = max(dot(n, l), 0.0);
  float n_v = max(dot(n, v), 1e-4);
  float n_h = max(dot(n, h), 0.0);
  float v_h = max(dot(v, h), 0.0);
  float metallic = d.params.x;
  float rough = clamp(d.params.y, 0.04, 1.0);
  float a = rough * rough;
  vec3 base = d.base_color.rgb;
  vec3 f0 = mix(vec3(0.04), base, metallic);
  vec3 fres = f0 + (1.0 - f0) * pow(1.0 - v_h, 5.0);
  vec3 spec = fres * d_ggx(n_h, a) * v_smith(n_v, n_l, a);
  vec3 diffuse = (1.0 - fres) * (1.0 - metallic) * base / PI;
  vec3 color = (diffuse + spec) * f.light_color.rgb * n_l;
  // Hemisphere ambient (sky above, darker ground bounce).
  float sky = 0.5 + 0.5 * n.y;
  color += base * (1.0 - metallic) * f.ambient.rgb * mix(0.4, 1.0, sky);
  out_color = vec4(color, 1.0);
}
