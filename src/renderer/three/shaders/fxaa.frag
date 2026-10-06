#version 450
// FXAA (simplified 3.11 "quality" edge walk, 8 steps) on the tonemapped image.
// tex0 = premultiplied gamma RGBA8. p2 = (1/w, 1/h).
#include "post.glsl"

layout(location = 0) out vec4 out_color;

float lum(vec2 uv) { return luma(texture(tex0, uv).rgb); }

void main() {
  vec2 px = P.p2.xy;
  vec2 uv = gl_FragCoord.xy * px;
  vec4 center = texture(tex0, uv);
  float m = luma(center.rgb);
  float n = lum(uv + vec2(0.0, -px.y));
  float s = lum(uv + vec2(0.0, px.y));
  float e = lum(uv + vec2(px.x, 0.0));
  float w = lum(uv + vec2(-px.x, 0.0));
  float lo = min(m, min(min(n, s), min(e, w)));
  float hi = max(m, max(max(n, s), max(e, w)));
  float range = hi - lo;
  if (range < max(0.0312, hi * 0.125)) { out_color = center; return; }
  float nw = lum(uv + vec2(-px.x, -px.y));
  float ne = lum(uv + vec2(px.x, -px.y));
  float sw = lum(uv + vec2(-px.x, px.y));
  float se = lum(uv + vec2(px.x, px.y));
  float horiz = abs(nw + ne - 2.0 * n) + 2.0 * abs(w + e - 2.0 * m) + abs(sw + se - 2.0 * s);
  float vert = abs(nw + sw - 2.0 * w) + 2.0 * abs(n + s - 2.0 * m) + abs(ne + se - 2.0 * e);
  bool is_h = horiz >= vert;
  float l1 = is_h ? n : w;
  float l2 = is_h ? s : e;
  float g1 = abs(l1 - m);
  float g2 = abs(l2 - m);
  float step_len = is_h ? px.y : px.x;
  float grad = max(g1, g2);
  float edge_l = 0.5 * (m + (g1 >= g2 ? l1 : l2));
  if (g1 >= g2) step_len = -step_len;
  vec2 euv = uv;
  if (is_h) euv.y += step_len * 0.5; else euv.x += step_len * 0.5;
  vec2 off = is_h ? vec2(px.x, 0.0) : vec2(0.0, px.y);
  vec2 uv1 = euv - off;
  vec2 uv2 = euv + off;
  float e1 = lum(uv1) - edge_l;
  float e2 = lum(uv2) - edge_l;
  bool done1 = abs(e1) >= grad * 0.25;
  bool done2 = abs(e2) >= grad * 0.25;
  for (int i = 0; i < 8; i++) {
    if (done1 && done2) break;
    if (!done1) { uv1 -= off * 1.5; e1 = lum(uv1) - edge_l; done1 = abs(e1) >= grad * 0.25; }
    if (!done2) { uv2 += off * 1.5; e2 = lum(uv2) - edge_l; done2 = abs(e2) >= grad * 0.25; }
  }
  float d1 = is_h ? uv.x - uv1.x : uv.y - uv1.y;
  float d2 = is_h ? uv2.x - uv.x : uv2.y - uv.y;
  bool near1 = d1 < d2;
  float dist = min(d1, d2);
  float span = d1 + d2;
  bool correct = ((near1 ? e1 : e2) < 0.0) != (m - edge_l < 0.0);
  float offset = correct ? -dist / span + 0.5 : 0.0;
  float sub = clamp(abs((2.0 * (n + s + e + w) + nw + ne + sw + se) / 12.0 - m) / range, 0.0, 1.0);
  float sub_off = (-2.0 * sub + 3.0) * sub * sub;
  offset = max(offset, sub_off * sub_off * 0.75);
  vec2 fuv = uv;
  if (is_h) fuv.y += offset * step_len; else fuv.x += offset * step_len;
  out_color = texture(tex0, fuv);
}
