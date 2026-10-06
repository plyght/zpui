#version 450
// Separable gaussian. tex0 = source (premultiplied or AO), tex1 = AO (optional multiply).
// p0 = (dir.x, dir.y, sigma in source texels, multiply-by-AO flag),
// p1 = (1/w, 1/h of the source, dst-to-src scale, AO strength).
#include "post.glsl"

layout(location = 0) out vec4 out_color;

vec4 fetch(vec2 uv) {
  vec4 c = texture(tex0, uv);
  if (P.p0.w > 0.5) c.rgb *= mix(1.0, texture(tex1, uv).r, P.p1.w);
  return c;
}

void main() {
  vec2 uv = gl_FragCoord.xy * P.p1.z * P.p1.xy;
  vec2 dir = P.p0.xy * P.p1.xy;
  float sigma = max(P.p0.z, 0.5);
  int radius = min(int(ceil(sigma * 3.0)), 24);
  vec4 sum = fetch(uv);
  float wsum = 1.0;
  for (int i = 1; i <= 24; i++) {
    if (i > radius) break;
    float w = exp(-0.5 * float(i * i) / (sigma * sigma));
    sum += (fetch(uv + dir * float(i)) + fetch(uv - dir * float(i))) * w;
    wsum += 2.0 * w;
  }
  out_color = sum / wsum;
}
