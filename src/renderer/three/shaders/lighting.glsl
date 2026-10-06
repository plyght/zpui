// zpui.three lighting helpers (fragment stages). Needs three.glsl first.
// Conventions follow three.js's physically based lights so style values port
// directly: diffuse = albedo / PI * (sun * NdotL * shadow + hemisphere + SH9).

const float PI = 3.14159265;

vec3 view_vector(vec3 world) {
  // Orthographic cameras: constant view direction (camera_pos.w = 1).
  if (FRAME.camera_pos.w > 0.5) return normalize(vec3(FRAME.view[0][2], FRAME.view[1][2], FRAME.view[2][2]));
  return normalize(FRAME.camera_pos.xyz - world);
}

float hash12(vec2 p) {
  uvec2 q = uvec2(ivec2(floor(p)) + ivec2(32768));
  uint h = q.x * 1597334677u ^ q.y * 3812015801u;
  h = (h ^ (h >> 16u)) * 2246822519u;
  h ^= h >> 13u;
  return float(h & 0xffffu) / 65535.0;
}

float value_noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash12(i);
  float b = hash12(i + vec2(1.0, 0.0));
  float c = hash12(i + vec2(0.0, 1.0));
  float d = hash12(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fixed 12-tap Poisson disc (deterministic: no per-pixel rotation).
const vec2 POISSON[12] = vec2[12](
  vec2(-0.326, -0.406), vec2(-0.840, -0.074), vec2(-0.696, 0.457), vec2(-0.203, 0.621),
  vec2(0.962, -0.195), vec2(0.473, -0.480), vec2(0.519, 0.767), vec2(0.185, -0.893),
  vec2(0.507, 0.064), vec2(0.896, 0.412), vec2(-0.322, -0.933), vec2(-0.792, -0.598));

float sample_shadow(sampler2DShadow map, vec3 lp) {
  if (FRAME.sun_dir.w < 0.5) return 1.0;
  vec2 uv = lp.xy * 0.5 + 0.5;
  if (uv.x <= 0.0 || uv.y <= 0.0 || uv.x >= 1.0 || uv.y >= 1.0 || lp.z >= 1.0) return 1.0;
  float ref = lp.z - FRAME.shadow.x;
  float radius = FRAME.shadow.w * FRAME.shadow.z;
  if (radius <= 0.0) return texture(map, vec3(uv, ref));
  float sum = texture(map, vec3(uv, ref));
  for (int i = 0; i < 12; i++) sum += texture(map, vec3(uv + POISSON[i] * radius, ref));
  return sum / 13.0;
}

vec3 sh_irradiance(vec3 n) {
  const float c1 = 0.429043, c2 = 0.511664, c3 = 0.743125, c4 = 0.886227, c5 = 0.247708;
  vec3 L00 = FRAME.sh[0].rgb, L1m1 = FRAME.sh[1].rgb, L10 = FRAME.sh[2].rgb, L11 = FRAME.sh[3].rgb;
  vec3 L2m2 = FRAME.sh[4].rgb, L2m1 = FRAME.sh[5].rgb, L20 = FRAME.sh[6].rgb, L21 = FRAME.sh[7].rgb, L22 = FRAME.sh[8].rgb;
  float x = n.x, y = n.y, z = n.z;
  vec3 e = c1 * L22 * (x * x - y * y) + c3 * L20 * z * z + c4 * L00 - c5 * L20
         + 2.0 * c1 * (L2m2 * x * y + L21 * x * z + L2m1 * y * z)
         + 2.0 * c2 * (L11 * x + L1m1 * y + L10 * z);
  return max(e, vec3(0.0)) * FRAME.env.x;
}

vec3 ambient_irradiance(vec3 n) {
  vec3 hemi = mix(FRAME.ground.rgb, FRAME.sky.rgb, n.y * 0.5 + 0.5);
  if (FRAME.env.x > 0.0) hemi += sh_irradiance(n);
  return hemi;
}

float d_ggx(float n_h, float a) {
  float a2 = a * a;
  float d = n_h * n_h * (a2 - 1.0) + 1.0;
  return a2 / (PI * d * d);
}

float v_smith(float n_v, float n_l, float a) {
  // Height-correlated Smith-GGX visibility (as three.js / glTF sample viewer).
  float a2 = a * a;
  float gv = n_l * sqrt(n_v * n_v * (1.0 - a2) + a2);
  float gl = n_v * sqrt(n_l * n_l * (1.0 - a2) + a2);
  return 0.5 / max(gv + gl, 1e-5);
}

vec3 shade_pbr(vec3 albedo, float metallic, float roughness, vec3 n, vec3 v, float shadow) {
  vec3 l = FRAME.sun_dir.xyz;
  vec3 h = normalize(v + l);
  float n_l = max(dot(n, l), 0.0);
  float n_v = max(dot(n, v), 1e-4);
  float n_h = max(dot(n, h), 0.0);
  float v_h = max(dot(v, h), 0.0);
  float a = roughness * roughness;
  vec3 f0 = mix(vec3(0.04), albedo, metallic);
  vec3 fres = f0 + (1.0 - f0) * pow(1.0 - v_h, 5.0);
  vec3 diffuse_color = albedo * (1.0 - metallic);
  vec3 spec = fres * d_ggx(n_h, a) * v_smith(n_v, n_l, a);
  vec3 direct = (diffuse_color / PI + spec) * FRAME.sun_color.rgb * n_l * shadow;
  vec3 indirect = diffuse_color / PI * ambient_irradiance(n);
  // Ambient specular: the hemisphere (+SH) seen along the reflection vector,
  // weighted by Karis' analytic split-sum approximation (UE4 mobile EnvBRDFApprox).
  vec3 r = reflect(-v, n);
  vec3 env = ambient_irradiance(normalize(mix(r, n, roughness * roughness))) / PI;
  const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
  const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
  vec4 rr = roughness * c0 + c1;
  float a004 = min(rr.x * rr.x, exp2(-9.28 * n_v)) * rr.x + rr.y;
  vec2 ab = vec2(-1.04, 1.04) * a004 + rr.zw;
  vec3 env_spec = env * (f0 * ab.x + ab.y);
  return direct + indirect + env_spec;
}

vec3 shade_toon(vec3 albedo, vec3 n, float shadow) {
  // As three.js MeshToonMaterial: ramp(N.L), then the shadow scales the light.
  float lit = max(dot(n, FRAME.sun_dir.xyz), 0.0);
  float bands = max(DRAW.toon.x, 1.0);
  float level = 0.0;
  float soft = max(DRAW.toon.z, 1e-4);
  for (int k = 1; k < 8; k++) {
    if (float(k) >= bands) break;
    float t = float(k) / bands;
    level += smoothstep(t - soft, t + soft, lit);
  }
  float ramp = bands > 1.0 ? DRAW.toon.y + (1.0 - DRAW.toon.y) * level / (bands - 1.0) : 1.0;
  return albedo / PI * (FRAME.sun_color.rgb * ramp * shadow + ambient_irradiance(n));
}

vec3 apply_fog(vec3 color, float view_depth) {
  float density = FRAME.fog.w;
  if (density <= 0.0) return color;
  float f = 1.0 - exp(-density * density * view_depth * view_depth);
  return mix(color, FRAME.fog.rgb, clamp(f, 0.0, 1.0));
}
