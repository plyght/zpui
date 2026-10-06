#version 450
#include "viewport3d.glsl"
layout(location = 0) in vec2 v_uv;
layout(location = 1) flat in uint v_instance;
layout(location = 2) in vec4 v_clip;
layout(location = 0) out vec4 out_color;

// Khronos PBR Neutral tone mapper (https://github.com/KhronosGroup/ToneMapping).
vec3 pbr_neutral(vec3 color) {
  const float start_compression = 0.8 - 0.04;
  const float desaturation = 0.15;
  float x = min(color.r, min(color.g, color.b));
  float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
  color -= offset;
  float peak = max(color.r, max(color.g, color.b));
  if (peak < start_compression) return color;
  const float d = 1.0 - start_compression;
  float new_peak = 1.0 - d * d / (peak + d - start_compression);
  color *= new_peak / peak;
  float g = 1.0 - 1.0 / (desaturation * (peak - new_peak) + 1.0);
  return mix(color, vec3(new_peak), g);
}

vec3 srgb_oetf(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
  if (any(lessThan(v_clip, vec4(0.0)))) discard;
  Viewport3DInstance vp = pc.instances.items[v_instance];
  // Resolved MSAA over a transparent clear: rgb is premultiplied by coverage.
  vec4 hdr = texture(hdr_texture, v_uv);
  if (hdr.a <= 0.0) discard;
  vec3 rgb = hdr.rgb / hdr.a * vp.exposure;
  vec3 encoded = srgb_oetf(clamp(pbr_neutral(rgb), 0.0, 1.0));
  float coverage = clamp(0.5 - quad_sdf(gl_FragCoord.xy, vp.bounds, vp.corner_radii), 0.0, 1.0);
  float alpha = hdr.a * coverage;
  out_color = vec4(encoded * alpha, alpha); // premultiplied
}
