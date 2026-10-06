#version 450
// HDR -> display: AO, tilt-shift mix, exposure, tonemap, saturation,
// vignette, sRGB encode. Output premultiplied gamma-space RGBA8 for the UI pass.
// tex0 = HDR (premultiplied), tex1 = AO, tex2 = blurred HDR.
// p0 = (exposure, tonemap, saturation, vignette), p1 = (AO strength (0 = off), focus, range, tilt on),
// p2 = (1/w, 1/h).
#include "post.glsl"

layout(location = 0) out vec4 out_color;

// Khronos PBR Neutral (https://github.com/KhronosGroup/ToneMapping).
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

// ACES filmic fit (Narkowicz 2015).
vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 srgb_oetf(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
  vec2 uv = gl_FragCoord.xy * P.p2.xy;
  vec4 c = texture(tex0, uv);
  if (P.p1.x > 0.0) c.rgb *= mix(1.0, texture(tex1, uv).r, P.p1.x);
  if (P.p1.w > 0.5) {
    float k = smoothstep(P.p1.z * 0.5, P.p1.z * 0.5 + 0.28, abs(uv.y - P.p1.y));
    c = mix(c, texture(tex2, uv), k);
  }
  if (c.a <= 0.0) { out_color = vec4(0.0); return; }
  vec3 rgb = c.rgb / c.a * P.p0.x;
  int tm = int(P.p0.y + 0.5);
  if (tm == 1) rgb = pbr_neutral(rgb);
  else if (tm == 2) rgb = aces(rgb);
  rgb = clamp(rgb, 0.0, 1.0);
  if (abs(P.p0.z - 1.0) > 1e-3) rgb = clamp(mix(vec3(luma(rgb)), rgb, P.p0.z), 0.0, 1.0);
  if (P.p0.w > 0.0) rgb *= 1.0 - smoothstep(0.35, 0.85, length(uv - 0.5)) * P.p0.w;
  float a = clamp(c.a, 0.0, 1.0);
  out_color = vec4(srgb_oetf(rgb) * a, a);
}
