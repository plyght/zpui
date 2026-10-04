// Shared definitions for the zpui Vulkan shaders. Ported from zui's
// crates/gpui_macos/src/shaders.metal (the visual reference); see
// docs/shaders-notes.md for the per-primitive math and line references.
//
// Instance data lives in host-visible buffers reached through
// GL_EXT_buffer_reference with scalar layout, so every struct below matches
// the `extern struct`s in src/scene.zig / src/color.zig / src/atlas.zig
// byte for byte (all members are 4-byte scalars).

#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

#define M_PI_F 3.1415926

struct Bounds { vec2 origin; vec2 size; };
struct Corners { float top_left; float top_right; float bottom_right; float bottom_left; };
struct Edges { float top; float right; float bottom; float left; };
struct Hsla { float h; float s; float l; float a; };
struct LinearColorStop { Hsla color; float percentage; };
struct Background {
  uint tag;
  uint color_space;
  Hsla solid;
  float gradient_angle_or_pattern_height;
  LinearColorStop colors[2];
  uint pad;
};
struct EdgeFadeParams {
  float top_y; float bottom_y; float band_top; float band_bottom;
  float left_x; float right_x; float band_left; float band_right;
};
struct AtlasTile { uint texture_index; uint texture_kind; uint tile_id; uint padding; ivec2 origin; ivec2 size; };
// Row-major 2x2 rotation/scale: m[row][col] = (m00, m01, m10, m11).
struct TransformationMatrix { float m00; float m01; float m10; float m11; vec2 translation; };

// Push constants shared by every pipeline (128 bytes max, see Renderer.zig).
// `instances` is the device address of this draw's instance array.
#define PUSH_CONSTANTS(InstanceType)                                    \
  layout(push_constant, scalar) uniform PushConstants {                 \
    InstanceType instances;                                             \
    vec2 viewport_size;                                                 \
    vec2 texture_size;                                                  \
    vec4 params0;                                                       \
    vec4 params1;                                                       \
  } pc;

// Metal's unit quad: two triangles, 6 vertices (MR:321).
const vec2 UNIT_VERTICES[6] = vec2[6](
  vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
  vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

// Vulkan NDC has +y pointing down, so unlike Metal there is no y flip.
vec4 to_device_position_impl(vec2 position, vec2 viewport_size) {
  return vec4(position / viewport_size * 2.0 - 1.0, 0.0, 1.0);
}

vec2 unit_position(vec2 unit_vertex, Bounds bounds) {
  return unit_vertex * bounds.size + bounds.origin;
}

vec2 apply_transform(vec2 p, TransformationMatrix t) {
  return vec2(p.x * t.m00 + p.y * t.m01, p.x * t.m10 + p.y * t.m11) + t.translation;
}

vec4 distance_from_clip_rect_impl(vec2 position, Bounds clip_bounds) {
  return vec4(position.x - clip_bounds.origin.x,
              clip_bounds.origin.x + clip_bounds.size.x - position.x,
              position.y - clip_bounds.origin.y,
              clip_bounds.origin.y + clip_bounds.size.y - position.y);
}

vec2 to_tile_position(vec2 unit_vertex, AtlasTile tile, vec2 atlas_size) {
  return (vec2(tile.origin) + unit_vertex * vec2(tile.size)) / atlas_size;
}

// Metal's `fmod` keeps the sign of the dividend (truncated), unlike GLSL `mod`.
float fmod_t(float a, float b) { return a - b * trunc(a / b); }

vec4 hsla_to_rgba(Hsla hsla) {
  float h = hsla.h * 6.0;
  float s = hsla.s;
  float l = hsla.l;
  float c = (1.0 - abs(2.0 * l - 1.0)) * s;
  float x = c * (1.0 - abs(fmod_t(h, 2.0) - 1.0));
  float m = l - c / 2.0;
  vec3 rgb;
  if (h >= 0.0 && h < 1.0) rgb = vec3(c, x, 0.0);
  else if (h >= 1.0 && h < 2.0) rgb = vec3(x, c, 0.0);
  else if (h >= 2.0 && h < 3.0) rgb = vec3(0.0, c, x);
  else if (h >= 3.0 && h < 4.0) rgb = vec3(0.0, x, c);
  else if (h >= 4.0 && h < 5.0) rgb = vec3(x, 0.0, c);
  else rgb = vec3(c, 0.0, x);
  return vec4(rgb + m, hsla.a);
}

// Metal's gamma-2.2 approximation (M:974-980), used consistently.
vec3 srgb_to_linear(vec3 color) { return pow(max(color, vec3(0.0)), vec3(2.2)); }
vec3 linear_to_srgb(vec3 color) { return pow(max(color, vec3(0.0)), vec3(1.0 / 2.2)); }

vec4 srgb_to_oklab(vec4 color) {
  vec3 c = srgb_to_linear(color.rgb);
  float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
  float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
  float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
  float l_ = pow(l, 1.0 / 3.0);
  float m_ = pow(m, 1.0 / 3.0);
  float s_ = pow(s, 1.0 / 3.0);
  return vec4(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
              1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
              0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
              color.a);
}

vec4 oklab_to_srgb(vec4 color) {
  float l_ = color.r + 0.3963377774 * color.g + 0.2158037573 * color.b;
  float m_ = color.r - 0.1055613458 * color.g - 0.0638541728 * color.b;
  float s_ = color.r - 0.0894841775 * color.g - 1.2914855480 * color.b;
  float l = l_ * l_ * l_;
  float m = m_ * m_ * m_;
  float s = s_ * s_ * s_;
  vec3 linear_rgb = vec3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                         -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                         -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
  return vec4(linear_to_srgb(linear_rgb), color.a);
}

float pick_corner_radius(vec2 center_to_point, Corners r) {
  if (center_to_point.x < 0.0) {
    return center_to_point.y < 0.0 ? r.top_left : r.bottom_left;
  }
  return center_to_point.y < 0.0 ? r.top_right : r.bottom_right;
}

float quad_sdf_impl(vec2 corner_center_to_point, float corner_radius) {
  if (corner_radius == 0.0) {
    return max(corner_center_to_point.x, corner_center_to_point.y);
  }
  float signed_distance_to_inset_quad =
      length(max(vec2(0.0), corner_center_to_point)) +
      min(0.0, max(corner_center_to_point.x, corner_center_to_point.y));
  return signed_distance_to_inset_quad - corner_radius;
}

// Signed distance to the rounded rect: positive outside, negative inside.
float quad_sdf(vec2 point, Bounds bounds, Corners corner_radii) {
  vec2 half_size = bounds.size / 2.0;
  vec2 center = bounds.origin + half_size;
  vec2 center_to_point = point - center;
  float corner_radius = pick_corner_radius(center_to_point, corner_radii);
  vec2 corner_to_point = abs(center_to_point) - half_size;
  vec2 corner_center_to_point = corner_to_point + corner_radius;
  return quad_sdf_impl(corner_center_to_point, corner_radius);
}

vec4 over(vec4 below, vec4 above) {
  float alpha = above.a + below.a * (1.0 - above.a);
  // Metal divides by zero here when both are transparent; return transparent instead of NaN.
  if (alpha <= 0.0) return vec4(0.0);
  vec3 rgb = (above.rgb * above.a + below.rgb * below.a * (1.0 - above.a)) / alpha;
  return vec4(rgb, alpha);
}

// zui scoped edge fade (M:739): squared min ramp over enabled edges.
float edge_fade_alpha(vec2 position, EdgeFadeParams fade) {
  float ramp = 1.0;
  if (fade.band_top > 0.0) ramp = min(ramp, clamp((position.y - fade.top_y) / fade.band_top, 0.0, 1.0));
  if (fade.band_bottom > 0.0) ramp = min(ramp, clamp((fade.bottom_y - position.y) / fade.band_bottom, 0.0, 1.0));
  if (fade.band_left > 0.0) ramp = min(ramp, clamp((position.x - fade.left_x) / fade.band_left, 0.0, 1.0));
  if (fade.band_right > 0.0) ramp = min(ramp, clamp((fade.right_x - position.x) / fade.band_right, 0.0, 1.0));
  return ramp * ramp;
}

struct GradientColor { vec4 solid; vec4 color0; vec4 color1; };

GradientColor prepare_fill_color(Background bg) {
  GradientColor g;
  g.solid = vec4(0.0);
  g.color0 = vec4(0.0);
  g.color1 = vec4(0.0);
  if (bg.tag == 0u || bg.tag == 2u || bg.tag == 3u) {
    g.solid = hsla_to_rgba(bg.solid);
  } else if (bg.tag == 1u) {
    g.color0 = hsla_to_rgba(bg.colors[0].color);
    g.color1 = hsla_to_rgba(bg.colors[1].color);
    if (bg.color_space == 1u) {
      g.color0 = srgb_to_oklab(g.color0);
      g.color1 = srgb_to_oklab(g.color1);
    }
  }
  return g;
}

// Metal `fill_color` (M:756), including the triangular gradient dither.
vec4 fill_color(Background bg, vec2 position, Bounds bounds, vec4 solid_color, vec4 color0, vec4 color1) {
  vec4 color = solid_color;
  if (bg.tag == 1u) {
    float radians = (fmod_t(bg.gradient_angle_or_pattern_height, 360.0) - 90.0) * (M_PI_F / 180.0);
    vec2 direction = vec2(cos(radians), sin(radians));
    if (bounds.size.x > bounds.size.y) {
      direction.y *= bounds.size.y / bounds.size.x;
    } else {
      direction.x *= bounds.size.x / bounds.size.y;
    }
    vec2 half_size = bounds.size / 2.0;
    vec2 center = bounds.origin + half_size;
    vec2 center_to_point = position - center;
    float t = dot(center_to_point, direction) / length(direction);
    if (abs(direction.x) > abs(direction.y)) {
      t = (t + half_size.x) / bounds.size.x;
    } else {
      t = (t + half_size.y) / bounds.size.y;
    }
    t = (t - bg.colors[0].percentage) / (bg.colors[1].percentage - bg.colors[0].percentage);
    t = clamp(t, 0.0, 1.0);
    if (bg.color_space == 1u) {
      color = oklab_to_srgb(mix(color0, color1, t));
    } else {
      color = mix(color0, color1, t);
    }
    vec2 seed = position * 0.6180339887;
    float r1 = fract(sin(dot(seed, vec2(12.9898, 78.233))) * 43758.5453);
    float r2 = fract(sin(dot(seed, vec2(39.3460, 11.135))) * 24634.6345);
    float tri = r1 + r2 - 1.0;
    color.rgb += tri * 2.0 / 255.0;
    color.a += tri * 3.0 / 255.0;
  } else if (bg.tag == 2u) {
    float h = bg.gradient_angle_or_pattern_height;
    float pattern_width = (h / 65535.0) / 255.0;
    float pattern_interval = fmod_t(h, 65535.0) / 255.0;
    float pattern_height = pattern_width + pattern_interval;
    float stripe_angle = M_PI_F / 4.0;
    float pattern_period = pattern_height * sin(stripe_angle);
    // Metal float2x2(c, -s, s, c) is column-major: columns (c,-s) and (s,c).
    float s = sin(stripe_angle);
    float c = cos(stripe_angle);
    vec2 rel = position - bounds.origin;
    vec2 rotated_point = vec2(c * rel.x + s * rel.y, -s * rel.x + c * rel.y);
    float pattern = fmod_t(rotated_point.x, pattern_period);
    float distance = min(pattern, pattern_period - pattern) - pattern_period * (pattern_width / pattern_height) / 2.0;
    color = solid_color;
    color.a *= clamp(0.5 - distance, 0.0, 1.0);
  } else if (bg.tag == 3u) {
    float size = bg.gradient_angle_or_pattern_height;
    vec2 rel = position - bounds.origin;
    float x_index = floor(rel.x / size);
    float y_index = floor(rel.y / size);
    float should_be_colored = fmod_t(x_index + y_index, 2.0);
    color = solid_color;
    color.a *= clamp(should_be_colored, 0.0, 1.0);
  }
  return color;
}
