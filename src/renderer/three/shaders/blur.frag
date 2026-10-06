#version 450
// Separable gaussian, two taps per fetch (bilinear filtering between texel
// pairs). tex0 = source (premultiplied or AO), tex1 = AO (optional multiply).
// p0 = (dir.x, dir.y, sigma in source texels, multiply-by-AO flag),
// p1 = (1/w, 1/h of the source, dst-to-src scale, AO strength),
// p2 = (1/h of the target, tilt focus, half sharp band minus margin, skip on):
// rows inside the sharp band (never read by the resolve) are skipped.
#include "post.glsl"

layout(location = 0) out vec4 out_color;

vec4 fetch(vec2 uv) {
  vec4 c = texture(tex0, uv);
  if (P.p0.w > 0.5) c.rgb *= mix(1.0, texture(tex1, uv).r, P.p1.w);
  return c;
}

void main() {
  if (P.p2.w > 0.5 && abs(gl_FragCoord.y * P.p2.x - P.p2.y) < P.p2.z) { out_color = vec4(0.0); return; }
  vec2 uv = gl_FragCoord.xy * P.p1.z * P.p1.xy;
  vec2 dir = P.p0.xy * P.p1.xy;
  float sigma = max(P.p0.z, 0.5);
  int radius = min(int(ceil(sigma * 3.0)), 24);
  float k = -0.5 / (sigma * sigma);
  vec4 sum = fetch(uv);
  float wsum = 1.0;
  for (int i = 1; i <= 24; i += 2) {
    if (i > radius) break;
    float w1 = exp(k * float(i * i));
    float w2 = i + 1 <= radius ? exp(k * float((i + 1) * (i + 1))) : 0.0;
    float w = w1 + w2;
    float o = (float(i) * w1 + float(i + 1) * w2) / w;
    sum += (fetch(uv + dir * o) + fetch(uv - dir * o)) * w;
    wsum += 2.0 * w;
  }
  out_color = sum / wsum;
}
