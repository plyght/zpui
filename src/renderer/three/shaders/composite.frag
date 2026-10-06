#version 450
// Samples the post-processed (premultiplied, gamma) viewport image, clips to
// the content mask and rounds the corners exactly like zpui quads.
#include "post.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec2 v_pos;
layout(location = 0) out vec4 out_color;

float corner_sdf(vec2 point) {
  vec2 half_size = P.p0.zw * 0.5;
  vec2 center_to_point = point - (P.p0.xy + half_size);
  float r = center_to_point.x < 0.0 ? (center_to_point.y < 0.0 ? P.p2.x : P.p2.w) : (center_to_point.y < 0.0 ? P.p2.y : P.p2.z);
  vec2 cc = abs(center_to_point) - half_size + r;
  if (r == 0.0) return max(cc.x, cc.y);
  return length(max(vec2(0.0), cc)) + min(0.0, max(cc.x, cc.y)) - r;
}

void main() {
  vec2 p = gl_FragCoord.xy;
  if (p.x < P.p1.x || p.y < P.p1.y || p.x > P.p1.x + P.p1.z || p.y > P.p1.y + P.p1.w) discard;
  vec4 c = texture(tex0, v_uv);
  if (P.p3.w > 0.0) {
    // Upscaled image: unsharp mask clamped to the 4-neighborhood (no halos).
    vec2 px = 1.0 / vec2(textureSize(tex0, 0));
    vec4 n = texture(tex0, v_uv - vec2(0.0, px.y));
    vec4 s = texture(tex0, v_uv + vec2(0.0, px.y));
    vec4 e = texture(tex0, v_uv + vec2(px.x, 0.0));
    vec4 w = texture(tex0, v_uv - vec2(px.x, 0.0));
    vec4 lo = min(c, min(min(n, s), min(e, w)));
    vec4 hi = max(c, max(max(n, s), max(e, w)));
    c = clamp(c + (c - (n + s + e + w) * 0.25) * 2.0 * P.p3.w, lo, hi);
  }
  float coverage = clamp(0.5 - corner_sdf(p), 0.0, 1.0) * P.p3.z;
  out_color = c * coverage;
}
