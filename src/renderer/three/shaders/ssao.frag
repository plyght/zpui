#version 450
// zpui.three SSAO from the resolved depth buffer (reverse-Z): hemisphere
// samples around depth-derived normals, deterministic interleaved rotation.
// tex0 = depth. p0 = (radius, unused, samples, bias), p1 = (1/w, 1/h of the AO target).
#include "post.glsl"

layout(location = 0) out vec4 out_ao;

vec3 view_pos(vec2 uv, float depth) {
  vec4 p = FRAME.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
  return p.xyz / p.w;
}

// View-space z only (rows 2 and 3 of the inverse projection).
float view_z(vec2 uv, float depth) {
  vec4 v = vec4(uv * 2.0 - 1.0, depth, 1.0);
  mat4 m = FRAME.inv_proj;
  float z = m[0][2] * v.x + m[1][2] * v.y + m[2][2] * v.z + m[3][2];
  float w = m[0][3] * v.x + m[1][3] * v.y + m[2][3] * v.z + m[3][3];
  return z / w;
}

const vec3 KERNEL[16] = vec3[16](
  vec3(0.5381, 0.1856, 0.4319), vec3(0.1379, 0.2486, 0.4430), vec3(0.3371, 0.5679, 0.0057), vec3(-0.6999, -0.0451, 0.0019),
  vec3(0.0689, -0.1598, 0.8547), vec3(0.0560, 0.0069, 0.1843), vec3(-0.0146, 0.1402, 0.0762), vec3(0.0100, -0.1924, 0.0344),
  vec3(-0.3577, -0.5301, 0.4358), vec3(-0.3169, 0.1063, 0.0158), vec3(0.0103, -0.5869, 0.0046), vec3(-0.0897, -0.4940, 0.3287),
  vec3(0.7119, -0.0154, 0.0918), vec3(-0.0533, 0.0596, 0.5411), vec3(0.0352, -0.0631, 0.5460), vec3(-0.4776, 0.2847, 0.0271));

void main() {
  vec2 uv = gl_FragCoord.xy * P.p1.xy;
  float depth = texture(tex0, uv).r;
  if (depth <= 0.0) { out_ao = vec4(1.0); return; }
  vec3 p = view_pos(uv, depth);
  // Normal from the smaller of the one-sided differences per axis, so pixels on
  // a silhouette do not take the slope across the depth edge (no halos).
  vec2 dx = vec2(P.p1.x, 0.0);
  vec2 dy = vec2(0.0, P.p1.y);
  vec3 pr = view_pos(uv + dx, texture(tex0, uv + dx).r) - p;
  vec3 pl = p - view_pos(uv - dx, texture(tex0, uv - dx).r);
  vec3 pd = view_pos(uv + dy, texture(tex0, uv + dy).r) - p;
  vec3 pu = p - view_pos(uv - dy, texture(tex0, uv - dy).r);
  vec3 ddx = abs(pr.z) < abs(pl.z) ? pr : pl;
  vec3 ddy = abs(pd.z) < abs(pu.z) ? pd : pu;
  vec3 n = normalize(cross(ddx, ddy));
  if (dot(n, -p) < 0.0) n = -n;
  // Interleaved gradient noise rotates the kernel per pixel (stable, no texture).
  float angle = 6.2831853 * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  vec3 rnd = vec3(cos(angle), sin(angle), 0.0);
  vec3 t = normalize(rnd - n * dot(rnd, n));
  vec3 b = cross(n, t);
  mat3 tbn = mat3(t, b, n);
  float radius = P.p0.x;
  int count = clamp(int(P.p0.z), 4, 16);
  float occlusion = 0.0;
  for (int i = 0; i < 16; i++) {
    if (i >= count) break;
    vec3 k = KERNEL[i];
    k.z = abs(k.z);
    float scale = mix(0.2, 1.0, float(i + 1) / float(count));
    vec3 s = p + tbn * k * radius * scale;
    vec4 clip = FRAME.proj * vec4(s, 1.0);
    vec2 suv = clip.xy / clip.w * 0.5 + 0.5;
    if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) continue;
    float sd = texture(tex0, suv).r;
    if (sd <= 0.0) continue;
    float scene_z = view_z(suv, sd);
    float range = smoothstep(0.0, 1.0, radius / max(abs(p.z - scene_z), 1e-4));
    occlusion += (scene_z >= s.z + P.p0.w ? 1.0 : 0.0) * range;
  }
  out_ao = vec4(vec3(1.0 - occlusion / float(count)), 1.0);
}
