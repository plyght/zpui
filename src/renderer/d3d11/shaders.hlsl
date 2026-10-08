// zpui D3D11 shaders (vs_5_0 / ps_5_0). HLSL port of src/renderer/vulkan/shaders/*.glsl,
// which port zui's crates/gpui_macos/src/shaders.metal; see docs/shaders-notes.md for the
// per-primitive math. Instance arrays are StructuredBuffers whose element layouts match the
// `extern struct`s in src/scene.zig byte for byte (structured buffers are tightly packed,
// every member is a 4-byte scalar).
//
// Bindings: t0 = instances (VS + PS), t1 = texture (PS), s0 = linear clamp sampler,
// b0 = per-draw constants.

#define M_PI_F 3.1415926

cbuffer DrawConstants : register(b0) {
  float2 viewport_size;
  float2 texture_size;
  float4 params0;
  float4 params1;
  uint first_instance;
  uint3 _pad;
};

Texture2D<float4> tex : register(t1);
SamplerState samp : register(s0);

struct Bounds { float2 origin; float2 size; };
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
struct AtlasTile { uint texture_index; uint texture_kind; uint tile_id; uint padding; int2 origin; int2 size; };
struct TransformationMatrix { float m00; float m01; float m10; float m11; float2 translation; };

static const float2 UNIT_VERTICES[6] = {
  float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
  float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
};

// D3D NDC has +y up: flip.
float4 to_device_position(float2 position) {
  float2 ndc = position / viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
  return float4(ndc, 0.0, 1.0);
}

float2 unit_position(float2 unit_vertex, Bounds bounds) {
  return unit_vertex * bounds.size + bounds.origin;
}

float2 apply_transform(float2 p, TransformationMatrix t) {
  return float2(p.x * t.m00 + p.y * t.m01, p.x * t.m10 + p.y * t.m11) + t.translation;
}

float4 distance_from_clip_rect(float2 position, Bounds clip_bounds) {
  return float4(position.x - clip_bounds.origin.x,
                clip_bounds.origin.x + clip_bounds.size.x - position.x,
                position.y - clip_bounds.origin.y,
                clip_bounds.origin.y + clip_bounds.size.y - position.y);
}

float2 to_tile_position(float2 unit_vertex, AtlasTile tile) {
  return (float2(tile.origin) + unit_vertex * float2(tile.size)) / texture_size;
}

// HLSL fmod already truncates like Metal's.
float fmod_t(float a, float b) { return a - b * trunc(a / b); }

float4 hsla_to_rgba(Hsla hsla) {
  float h = hsla.h * 6.0;
  float s = hsla.s;
  float l = hsla.l;
  float c = (1.0 - abs(2.0 * l - 1.0)) * s;
  float x = c * (1.0 - abs(fmod_t(h, 2.0) - 1.0));
  float m = l - c / 2.0;
  float3 rgb;
  if (h >= 0.0 && h < 1.0) rgb = float3(c, x, 0.0);
  else if (h >= 1.0 && h < 2.0) rgb = float3(x, c, 0.0);
  else if (h >= 2.0 && h < 3.0) rgb = float3(0.0, c, x);
  else if (h >= 3.0 && h < 4.0) rgb = float3(0.0, x, c);
  else if (h >= 4.0 && h < 5.0) rgb = float3(x, 0.0, c);
  else rgb = float3(c, 0.0, x);
  return float4(rgb + m, hsla.a);
}

float3 srgb_to_linear(float3 color) { return pow(max(color, 0.0), 2.2); }
float3 linear_to_srgb(float3 color) { return pow(max(color, 0.0), 1.0 / 2.2); }

float4 srgb_to_oklab(float4 color) {
  float3 c = srgb_to_linear(color.rgb);
  float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
  float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
  float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
  float l_ = pow(max(l, 0.0), 1.0 / 3.0);
  float m_ = pow(max(m, 0.0), 1.0 / 3.0);
  float s_ = pow(max(s, 0.0), 1.0 / 3.0);
  return float4(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
                color.a);
}

float4 oklab_to_srgb(float4 color) {
  float l_ = color.r + 0.3963377774 * color.g + 0.2158037573 * color.b;
  float m_ = color.r - 0.1055613458 * color.g - 0.0638541728 * color.b;
  float s_ = color.r - 0.0894841775 * color.g - 1.2914855480 * color.b;
  float l = l_ * l_ * l_;
  float m = m_ * m_ * m_;
  float s = s_ * s_ * s_;
  float3 linear_rgb = float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                             -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                             -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
  return float4(linear_to_srgb(linear_rgb), color.a);
}

float pick_corner_radius(float2 center_to_point, Corners r) {
  if (center_to_point.x < 0.0) {
    return center_to_point.y < 0.0 ? r.top_left : r.bottom_left;
  }
  return center_to_point.y < 0.0 ? r.top_right : r.bottom_right;
}

float quad_sdf_impl(float2 corner_center_to_point, float corner_radius) {
  if (corner_radius == 0.0) {
    return max(corner_center_to_point.x, corner_center_to_point.y);
  }
  float signed_distance_to_inset_quad =
      length(max(float2(0.0, 0.0), corner_center_to_point)) +
      min(0.0, max(corner_center_to_point.x, corner_center_to_point.y));
  return signed_distance_to_inset_quad - corner_radius;
}

float quad_sdf(float2 p, Bounds bounds, Corners corner_radii) {
  float2 half_size = bounds.size / 2.0;
  float2 center = bounds.origin + half_size;
  float2 center_to_point = p - center;
  float corner_radius = pick_corner_radius(center_to_point, corner_radii);
  float2 corner_to_point = abs(center_to_point) - half_size;
  float2 corner_center_to_point = corner_to_point + corner_radius;
  return quad_sdf_impl(corner_center_to_point, corner_radius);
}

float4 over(float4 below, float4 above) {
  float alpha = above.a + below.a * (1.0 - above.a);
  if (alpha <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);
  float3 rgb = (above.rgb * above.a + below.rgb * below.a * (1.0 - above.a)) / alpha;
  return float4(rgb, alpha);
}

float edge_fade_alpha(float2 position, EdgeFadeParams fade) {
  float ramp = 1.0;
  if (fade.band_top > 0.0) ramp = min(ramp, saturate((position.y - fade.top_y) / fade.band_top));
  if (fade.band_bottom > 0.0) ramp = min(ramp, saturate((fade.bottom_y - position.y) / fade.band_bottom));
  if (fade.band_left > 0.0) ramp = min(ramp, saturate((position.x - fade.left_x) / fade.band_left));
  if (fade.band_right > 0.0) ramp = min(ramp, saturate((fade.right_x - position.x) / fade.band_right));
  return ramp * ramp;
}

struct GradientColor { float4 solid; float4 color0; float4 color1; };

GradientColor prepare_fill_color(Background bg) {
  GradientColor g;
  g.solid = float4(0.0, 0.0, 0.0, 0.0);
  g.color0 = float4(0.0, 0.0, 0.0, 0.0);
  g.color1 = float4(0.0, 0.0, 0.0, 0.0);
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

float4 fill_color(Background bg, float2 position, Bounds bounds, float4 solid_color, float4 color0, float4 color1) {
  float4 color = solid_color;
  if (bg.tag == 1u) {
    float radians = (fmod_t(bg.gradient_angle_or_pattern_height, 360.0) - 90.0) * (M_PI_F / 180.0);
    float2 direction = float2(cos(radians), sin(radians));
    if (bounds.size.x > bounds.size.y) {
      direction.y *= bounds.size.y / bounds.size.x;
    } else {
      direction.x *= bounds.size.x / bounds.size.y;
    }
    float2 half_size = bounds.size / 2.0;
    float2 center = bounds.origin + half_size;
    float2 center_to_point = position - center;
    float t = dot(center_to_point, direction) / length(direction);
    if (abs(direction.x) > abs(direction.y)) {
      t = (t + half_size.x) / bounds.size.x;
    } else {
      t = (t + half_size.y) / bounds.size.y;
    }
    t = (t - bg.colors[0].percentage) / (bg.colors[1].percentage - bg.colors[0].percentage);
    t = saturate(t);
    if (bg.color_space == 1u) {
      color = oklab_to_srgb(lerp(color0, color1, t));
    } else {
      color = lerp(color0, color1, t);
    }
    float2 seed = position * 0.6180339887;
    float r1 = frac(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
    float r2 = frac(sin(dot(seed, float2(39.3460, 11.135))) * 24634.6345);
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
    float s = sin(stripe_angle);
    float c = cos(stripe_angle);
    float2 rel = position - bounds.origin;
    float2 rotated_point = float2(c * rel.x + s * rel.y, -s * rel.x + c * rel.y);
    float pattern = fmod_t(rotated_point.x, pattern_period);
    float distance = min(pattern, pattern_period - pattern) - pattern_period * (pattern_width / pattern_height) / 2.0;
    color = solid_color;
    color.a *= saturate(0.5 - distance);
  } else if (bg.tag == 3u) {
    float size = bg.gradient_angle_or_pattern_height;
    float2 rel = position - bounds.origin;
    float x_index = floor(rel.x / size);
    float y_index = floor(rel.y / size);
    float should_be_colored = fmod_t(x_index + y_index, 2.0);
    color = solid_color;
    color.a *= saturate(should_be_colored);
  }
  return color;
}

// =========================================================================================
// Quads
// =========================================================================================

struct Quad {
  uint order;
  uint border_style;
  Bounds bounds;
  Bounds content_mask;
  Background background;
  Hsla border_color;
  Corners corner_radii;
  Edges border_widths;
  EdgeFadeParams fade;
};
StructuredBuffer<Quad> quads : register(t0);

struct QuadVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
  nointerpolation float4 border_color : COLOR0;
  nointerpolation float4 solid : COLOR1;
  nointerpolation float4 color0 : COLOR2;
  nointerpolation float4 color1 : COLOR3;
};

QuadVarying quad_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  uint id = instance_id + first_instance;
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  Quad quad = quads[id];
  float2 p = unit_position(unit_vertex, quad.bounds);
  QuadVarying o;
  o.position = to_device_position(p);
  o.clip = distance_from_clip_rect(p, quad.content_mask);
  o.id = id;
  o.border_color = hsla_to_rgba(quad.border_color);
  GradientColor g = prepare_fill_color(quad.background);
  o.solid = g.solid;
  o.color0 = g.color0;
  o.color1 = g.color1;
  return o;
}

float corner_dash_velocity(float dv1, float dv2) {
  if (dv1 == 0.0) return dv2;
  if (dv2 == 0.0) return dv1;
  return min(dv1, dv2);
}

float dash_alpha(float t, float period, float len, float dash_velocity, float antialias_threshold) {
  float half_period = period / 2.0;
  float half_length = len / 2.0;
  float centered = fmod_t(t + half_period - half_length, period) - half_period;
  float signed_distance = abs(centered) - half_length;
  return saturate(antialias_threshold - signed_distance / dash_velocity);
}

float quarter_ellipse_sdf(float2 p, float2 radii) {
  float2 circle_vec = p / radii;
  float unit_circle_sdf = length(circle_vec) - 1.0;
  return unit_circle_sdf * (radii.x + radii.y) * -0.5;
}

float4 quad_fragment(QuadVarying input) : SV_Target {
  Quad quad = quads[input.id];
  float2 frag = input.position.xy;
  float4 background_color = fill_color(quad.background, frag, quad.bounds, input.solid, input.color0, input.color1);
  float edge_fade = edge_fade_alpha(frag, quad.fade);
  background_color.a *= edge_fade;

  Corners r = quad.corner_radii;
  Edges bw = quad.border_widths;
  bool unrounded = r.top_left == 0.0 && r.bottom_left == 0.0 && r.top_right == 0.0 && r.bottom_right == 0.0;
  if (bw.top == 0.0 && bw.left == 0.0 && bw.right == 0.0 && bw.bottom == 0.0 && unrounded) {
    return background_color;
  }

  float2 size = quad.bounds.size;
  float2 half_size = size / 2.0;
  float2 p = frag - quad.bounds.origin;
  float2 center_to_point = p - half_size;
  const float antialias_threshold = 0.5;
  float corner_radius = pick_corner_radius(center_to_point, r);
  float2 border = float2(center_to_point.x < 0.0 ? bw.left : bw.right,
                         center_to_point.y < 0.0 ? bw.top : bw.bottom);
  float2 reduced_border = float2(border.x == 0.0 ? -antialias_threshold : border.x,
                                 border.y == 0.0 ? -antialias_threshold : border.y);
  float2 corner_to_point = abs(center_to_point) - half_size;
  float2 corner_center_to_point = corner_to_point + corner_radius;
  bool is_near_rounded_corner = corner_center_to_point.x >= 0.0 && corner_center_to_point.y >= 0.0;
  float2 straight_border_inner_corner_to_point = corner_to_point + reduced_border;
  bool is_beyond_inner_straight_border =
      straight_border_inner_corner_to_point.x > 0.0 || straight_border_inner_corner_to_point.y > 0.0;
  bool is_within_inner_straight_border =
      straight_border_inner_corner_to_point.x < -antialias_threshold &&
      straight_border_inner_corner_to_point.y < -antialias_threshold;
  if (is_within_inner_straight_border && !is_near_rounded_corner) {
    return background_color;
  }

  float outer_sdf = quad_sdf_impl(corner_center_to_point, corner_radius);
  float inner_sdf = 0.0;
  if (corner_center_to_point.x <= 0.0 || corner_center_to_point.y <= 0.0) {
    inner_sdf = -max(straight_border_inner_corner_to_point.x, straight_border_inner_corner_to_point.y);
  } else if (is_beyond_inner_straight_border) {
    inner_sdf = -1.0;
  } else if (reduced_border.x == reduced_border.y) {
    inner_sdf = -(outer_sdf + reduced_border.x);
  } else {
    float2 ellipse_radii = max(float2(0.0, 0.0), float2(corner_radius, corner_radius) - reduced_border);
    inner_sdf = quarter_ellipse_sdf(corner_center_to_point, ellipse_radii);
  }

  float border_sdf = max(inner_sdf, outer_sdf);
  float4 color = background_color;
  if (border_sdf < antialias_threshold) {
    float4 border_color = input.border_color;
    border_color.a *= edge_fade;

    if (quad.border_style == 1u) {
      float t = 0.0;
      float max_t = 0.0;
      const float dash_length_per_width = 2.0;
      const float dash_gap_per_width = 1.0;
      const float dash_period_per_width = dash_length_per_width + dash_gap_per_width;
      float dash_velocity = 0.0;
      const float dv_numerator = 1.0 / dash_period_per_width;

      if (unrounded) {
        bool is_horizontal = corner_center_to_point.x < corner_center_to_point.y;
        float2 dashed_border = float2(max(bw.bottom, bw.top), max(bw.right, bw.left));
        float border_width = is_horizontal ? dashed_border.x : dashed_border.y;
        dash_velocity = dv_numerator / border_width;
        t = (is_horizontal ? p.x : p.y) * dash_velocity;
        max_t = (is_horizontal ? size.x : size.y) * dash_velocity;
      } else {
        float r_tr = r.top_right;
        float r_br = r.bottom_right;
        float r_bl = r.bottom_left;
        float r_tl = r.top_left;
        float dv_t = bw.top <= 0.0 ? 0.0 : dv_numerator / bw.top;
        float dv_r = bw.right <= 0.0 ? 0.0 : dv_numerator / bw.right;
        float dv_b = bw.bottom <= 0.0 ? 0.0 : dv_numerator / bw.bottom;
        float dv_l = bw.left <= 0.0 ? 0.0 : dv_numerator / bw.left;
        float s_t = (size.x - r_tl - r_tr) * dv_t;
        float s_r = (size.y - r_tr - r_br) * dv_r;
        float s_b = (size.x - r_br - r_bl) * dv_b;
        float s_l = (size.y - r_bl - r_tl) * dv_l;
        float cdv_tr = corner_dash_velocity(dv_t, dv_r);
        float cdv_br = corner_dash_velocity(dv_b, dv_r);
        float cdv_bl = corner_dash_velocity(dv_b, dv_l);
        float cdv_tl = corner_dash_velocity(dv_t, dv_l);
        float c_tr = r_tr * (M_PI_F / 2.0) * cdv_tr;
        float c_br = r_br * (M_PI_F / 2.0) * cdv_br;
        float c_bl = r_bl * (M_PI_F / 2.0) * cdv_bl;
        float c_tl = r_tl * (M_PI_F / 2.0) * cdv_tl;
        float upto_tr = s_t;
        float upto_r = upto_tr + c_tr;
        float upto_br = upto_r + s_r;
        float upto_b = upto_br + c_br;
        float upto_bl = upto_b + s_b;
        float upto_l = upto_bl + c_bl;
        float upto_tl = upto_l + s_l;
        max_t = upto_tl + c_tl;

        if (is_near_rounded_corner) {
          float radians = atan2(corner_center_to_point.y, corner_center_to_point.x);
          float corner_t = radians * corner_radius;
          if (center_to_point.x >= 0.0) {
            if (center_to_point.y < 0.0) {
              dash_velocity = cdv_tr;
              t = upto_r - corner_t * dash_velocity;
            } else {
              dash_velocity = cdv_br;
              t = upto_br + corner_t * dash_velocity;
            }
          } else {
            if (center_to_point.y >= 0.0) {
              dash_velocity = cdv_bl;
              t = upto_l - corner_t * dash_velocity;
            } else {
              dash_velocity = cdv_tl;
              t = upto_tl + corner_t * dash_velocity;
            }
          }
        } else {
          bool is_horizontal = corner_center_to_point.x < corner_center_to_point.y;
          if (is_horizontal) {
            if (center_to_point.y < 0.0) {
              dash_velocity = dv_t;
              t = (p.x - r_tl) * dash_velocity;
            } else {
              dash_velocity = dv_b;
              t = upto_bl - (p.x - r_bl) * dash_velocity;
            }
          } else {
            if (center_to_point.x < 0.0) {
              dash_velocity = dv_l;
              t = upto_tl - (p.y - r_tl) * dash_velocity;
            } else {
              dash_velocity = dv_r;
              t = upto_r + (p.y - r_tr) * dash_velocity;
            }
          }
        }
      }

      float dash_length = dash_length_per_width / dash_period_per_width;
      max_t -= unrounded ? dash_length : 0.0;
      if (max_t >= 1.0) {
        float dash_count = floor(max_t);
        float dash_period = max_t / dash_count;
        border_color.a *= dash_alpha(t, dash_period, dash_length, dash_velocity, antialias_threshold);
      } else if (unrounded) {
        float dash_gap = max_t - dash_length;
        if (dash_gap > 0.0) {
          float dash_period = dash_length + dash_gap;
          border_color.a *= dash_alpha(t, dash_period, dash_length, dash_velocity, antialias_threshold);
        }
      }
    }

    float4 blended_border = over(background_color, border_color);
    color = lerp(background_color, blended_border, saturate(antialias_threshold - inner_sdf));
  }

  return color * float4(1.0, 1.0, 1.0, saturate(antialias_threshold - outer_sdf));
}

// =========================================================================================
// Shadows
// =========================================================================================

struct Shadow {
  uint order;
  float blur_radius;
  Bounds bounds;
  Corners corner_radii;
  Bounds content_mask;
  Hsla color;
  Bounds element_bounds;
  Corners element_corner_radii;
  uint inset;
  uint pad;
};
StructuredBuffer<Shadow> shadows : register(t0);

struct ShadowVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
  nointerpolation float4 color : COLOR0;
};

ShadowVarying shadow_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  uint id = instance_id + first_instance;
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  Shadow shadow = shadows[id];
  Bounds bounds;
  if (shadow.inset != 0u) {
    bounds = shadow.element_bounds;
  } else {
    float margin = 3.0 * shadow.blur_radius;
    bounds = shadow.bounds;
    bounds.origin -= margin;
    bounds.size += 2.0 * margin;
  }
  float2 p = unit_position(unit_vertex, bounds);
  ShadowVarying o;
  o.position = to_device_position(p);
  o.clip = distance_from_clip_rect(p, shadow.content_mask);
  o.id = id;
  o.color = hsla_to_rgba(shadow.color);
  return o;
}

float gaussian(float x, float sigma) {
  return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

float2 erf_approx(float2 x) {
  float2 s = sign(x);
  float2 a = abs(x);
  float2 r1 = 1.0 + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;
  float2 r2 = r1 * r1;
  return s - s / (r2 * r2);
}

float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {
  float delta = min(half_size.y - corner - abs(y), 0.0);
  float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
  float2 integral = 0.5 + 0.5 * erf_approx((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
  return integral.y - integral.x;
}

float4 shadow_fragment(ShadowVarying input) : SV_Target {
  Shadow shadow = shadows[input.id];
  float2 frag = input.position.xy;
  float2 half_size = shadow.bounds.size / 2.0;
  float2 center = shadow.bounds.origin + half_size;
  float2 p = frag - center;
  float corner_radius = pick_corner_radius(p, shadow.corner_radii);

  float alpha;
  if (shadow.blur_radius == 0.0) {
    alpha = saturate(0.5 - quad_sdf(frag, shadow.bounds, shadow.corner_radii));
  } else {
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3.0 * shadow.blur_radius, low, high);
    float end = clamp(3.0 * shadow.blur_radius, low, high);
    float step_size = (end - start) / 4.0;
    float y = start + step_size * 0.5;
    alpha = 0.0;
    [unroll] for (int i = 0; i < 4; i++) {
      alpha += blur_along_x(p.x, p.y - y, shadow.blur_radius, corner_radius, half_size) *
               gaussian(y, shadow.blur_radius) * step_size;
      y += step_size;
    }
  }

  if (shadow.inset != 0u) {
    alpha = 1.0 - alpha;
    float element_distance = quad_sdf(frag, shadow.element_bounds, shadow.element_corner_radii);
    alpha *= saturate(0.5 - element_distance);
  }
  return input.color * float4(1.0, 1.0, 1.0, alpha);
}

// =========================================================================================
// Underlines
// =========================================================================================

struct Underline {
  uint order;
  uint pad;
  Bounds bounds;
  Bounds content_mask;
  Hsla color;
  float thickness;
  uint wavy;
};
StructuredBuffer<Underline> underlines : register(t0);

struct UnderlineVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
  nointerpolation float4 color : COLOR0;
};

UnderlineVarying underline_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  uint id = instance_id + first_instance;
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  Underline u = underlines[id];
  float2 p = unit_position(unit_vertex, u.bounds);
  UnderlineVarying o;
  o.position = to_device_position(p);
  o.clip = distance_from_clip_rect(p, u.content_mask);
  o.id = id;
  o.color = hsla_to_rgba(u.color);
  return o;
}

float4 underline_fragment(UnderlineVarying input) : SV_Target {
  const float WAVE_FREQUENCY = 2.0;
  const float WAVE_HEIGHT_RATIO = 0.8;
  Underline u = underlines[input.id];
  if (u.wavy != 0u) {
    float half_thickness = u.thickness * 0.5;
    float h = u.bounds.size.y;
    float2 st = ((input.position.xy - u.bounds.origin) / h) - float2(0.0, 0.5);
    float frequency = (M_PI_F * WAVE_FREQUENCY * u.thickness) / h;
    float amplitude = (u.thickness * WAVE_HEIGHT_RATIO) / h;
    float sine = sin(st.x * frequency) * amplitude;
    float dsine = cos(st.x * frequency) * amplitude * frequency;
    float distance = (st.y - sine) / sqrt(1.0 + dsine * dsine);
    float distance_in_pixels = distance * h;
    float distance_from_top_border = distance_in_pixels - half_thickness;
    float distance_from_bottom_border = distance_in_pixels + half_thickness;
    float alpha = saturate(0.5 - max(-distance_from_bottom_border, distance_from_top_border));
    return input.color * float4(1.0, 1.0, 1.0, alpha);
  }
  return input.color;
}

// =========================================================================================
// Monochrome + subpixel sprites (one layout)
// =========================================================================================

struct MonochromeSprite {
  uint order;
  uint pad;
  Bounds bounds;
  Bounds content_mask;
  Hsla color;
  AtlasTile tile;
  TransformationMatrix transformation;
  EdgeFadeParams fade;
  float blur;
  float pad2;
};
StructuredBuffer<MonochromeSprite> mono_sprites : register(t0);

struct SpriteVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
  nointerpolation float4 color : COLOR0;
  float2 tile_position : TEXCOORD1;
};

SpriteVarying mono_sprite_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  uint id = instance_id + first_instance;
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  MonochromeSprite sprite = mono_sprites[id];
  float2 p = apply_transform(unit_position(unit_vertex, sprite.bounds), sprite.transformation);
  SpriteVarying o;
  o.position = to_device_position(p);
  o.clip = distance_from_clip_rect(p, sprite.content_mask);
  o.id = id;
  o.color = hsla_to_rgba(sprite.color);
  float blur_pad = 3.0 * sprite.blur;
  float2 quad_size = sprite.bounds.size;
  float2 unpadded_size = max(quad_size - 2.0 * blur_pad, float2(1e-6, 1e-6));
  float2 tile_size = float2(sprite.tile.size);
  float2 tile_px = (unit_vertex * quad_size - blur_pad) * (tile_size / unpadded_size);
  o.tile_position = (float2(sprite.tile.origin) + tile_px) / texture_size;
  return o;
}

float4 mono_sprite_fragment(SpriteVarying input) : SV_Target {
  MonochromeSprite sprite = mono_sprites[input.id];
  float coverage;
  if (sprite.blur > 0.0) {
    float sigma = sprite.blur;
    float2 texel = 1.0 / texture_size;
    float2 tile_min = float2(sprite.tile.origin) / texture_size;
    float2 tile_max = tile_min + float2(sprite.tile.size) / texture_size;
    float2 tile_mid = 0.5 * (tile_min + tile_max);
    float2 inset_min = min(tile_min + 0.5 * texel, tile_mid);
    float2 inset_max = max(tile_max - 0.5 * texel, tile_mid);
    int radius = min(int(ceil(3.0 * sigma)), 12);
    float accum = 0.0;
    float total = 0.0;
    for (int y = -radius; y <= radius; y++) {
      for (int x = -radius; x <= radius; x++) {
        float2 offset = float2(x, y);
        float weight = exp(-dot(offset, offset) / (2.0 * sigma * sigma));
        float2 uv = input.tile_position + offset * texel;
        float tap = 0.0;
        if (all(uv >= tile_min) && all(uv <= tile_max)) {
          tap = tex.SampleLevel(samp, clamp(uv, inset_min, inset_max), 0.0).r;
        }
        accum += weight * tap;
        total += weight;
      }
    }
    coverage = accum / max(total, 1e-6);
  } else {
    coverage = tex.SampleLevel(samp, input.tile_position, 0.0).r;
  }
  float4 color = input.color;
  color.a *= coverage * edge_fade_alpha(input.position.xy, sprite.fade);
  return color;
}

struct DualSourceOut {
  float4 color : SV_Target0;
  float4 alpha : SV_Target1;
};

DualSourceOut subpixel_sprite_fragment(SpriteVarying input) {
  float3 coverage = tex.SampleLevel(samp, input.tile_position, 0.0).rgb;
  if (params0.x != 0.0) coverage = coverage.bgr;
  float3 alpha = input.color.a * coverage * edge_fade_alpha(input.position.xy, mono_sprites[input.id].fade);
  float mean = (alpha.r + alpha.g + alpha.b) / 3.0;
  DualSourceOut o;
  o.color = float4(input.color.rgb, mean);
  o.alpha = float4(alpha, mean);
  return o;
}

// =========================================================================================
// Polychrome sprites
// =========================================================================================

struct ImageAlphaMaskParams {
  Bounds bounds;
  float radius;
  float feather;
  float clearance;
  float bottom_y;
  float bottom_feather;
  float pad;
};
struct PolychromeSprite {
  uint order;
  uint pad;
  uint grayscale;
  float opacity;
  Bounds bounds;
  Bounds content_mask;
  Corners corner_radii;
  EdgeFadeParams fade;
  ImageAlphaMaskParams alpha_mask;
  AtlasTile tile;
};
StructuredBuffer<PolychromeSprite> poly_sprites : register(t0);

struct PolySpriteVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
  float2 tile_position : TEXCOORD1;
};

PolySpriteVarying poly_sprite_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  uint id = instance_id + first_instance;
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  PolychromeSprite sprite = poly_sprites[id];
  float2 p = unit_position(unit_vertex, sprite.bounds);
  PolySpriteVarying o;
  o.position = to_device_position(p);
  o.clip = distance_from_clip_rect(p, sprite.content_mask);
  o.id = id;
  o.tile_position = to_tile_position(unit_vertex, sprite.tile);
  return o;
}

float image_mask_alpha(float2 position, ImageAlphaMaskParams mask) {
  if (mask.feather <= 0.0) return 1.0;
  float2 half_size = mask.bounds.size * 0.5;
  float2 center = mask.bounds.origin + half_size;
  float2 q = abs(position - center) - half_size + mask.radius;
  float distance = length(max(q, float2(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - mask.radius;
  float alpha = smoothstep(0.0, mask.feather, distance - mask.clearance);
  if (mask.bottom_feather > 0.0)
    alpha = min(alpha, smoothstep(0.0, mask.bottom_feather, mask.bottom_y - position.y));
  return alpha;
}

float4 poly_sprite_fragment(PolySpriteVarying input) : SV_Target {
  PolychromeSprite sprite = poly_sprites[input.id];
  float2 frag = input.position.xy;
  float4 color = tex.SampleLevel(samp, input.tile_position, 0.0);
  float distance = quad_sdf(frag, sprite.bounds, sprite.corner_radii);
  if (sprite.grayscale != 0u) {
    float g = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    color.rgb = float3(g, g, g);
  }
  color.a *= sprite.opacity * saturate(0.5 - distance) *
             edge_fade_alpha(frag, sprite.fade) * image_mask_alpha(frag, sprite.alpha_mask);
  return color;
}

// =========================================================================================
// Paths: rasterize into a (4x MSAA) intermediate, then copy the covered rects.
// =========================================================================================

struct PathRasterizationVertex {
  float2 xy_position;
  float2 st_position;
  Background color;
  Bounds bounds;
};
StructuredBuffer<PathRasterizationVertex> path_vertices : register(t0);

struct PathVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
  float2 st : TEXCOORD1;
};

PathVarying path_rasterization_vertex(uint vertex_id : SV_VertexID) {
  uint id = vertex_id + first_instance;
  PathRasterizationVertex v = path_vertices[id];
  PathVarying o;
  o.position = to_device_position(v.xy_position);
  o.clip = distance_from_clip_rect(v.xy_position, v.bounds);
  o.id = id;
  o.st = v.st_position;
  return o;
}

float4 path_rasterization_fragment(PathVarying input) : SV_Target {
  float2 dx = ddx(input.st);
  float2 dy = ddy(input.st);
  PathRasterizationVertex v = path_vertices[input.id];
  float alpha;
  if (length(float2(dx.x, dy.x)) < 0.001) {
    alpha = 1.0;
  } else {
    float2 gradient = float2((2.0 * input.st.x) * dx.x - dx.y, (2.0 * input.st.x) * dy.x - dy.y);
    float f = (input.st.x * input.st.x) - input.st.y;
    float distance = f / length(gradient);
    alpha = saturate(0.5 - distance);
  }
  GradientColor g = prepare_fill_color(v.color);
  float4 color = fill_color(v.color, input.position.xy, v.bounds, g.solid, g.color0, g.color1);
  return float4(color.rgb * color.a * alpha, alpha * color.a);
}

struct PathSprite { Bounds bounds; };
StructuredBuffer<PathSprite> path_sprites : register(t0);

struct PathSpriteVarying {
  float4 position : SV_Position;
  float2 uv : TEXCOORD0;
};

PathSpriteVarying path_sprite_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  PathSprite sprite = path_sprites[instance_id + first_instance];
  float2 p = unit_position(unit_vertex, sprite.bounds);
  PathSpriteVarying o;
  o.position = to_device_position(p);
  o.uv = p / viewport_size;
  return o;
}

float4 path_sprite_fragment(PathSpriteVarying input) : SV_Target {
  return tex.SampleLevel(samp, input.uv, 0.0);
}

// =========================================================================================
// Backdrop blur: separable gaussian passes + rounded composite.
// =========================================================================================

float4 blur_pass_vertex(uint vertex_id : SV_VertexID) : SV_Position {
  float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
  return float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

//   params0 = (direction.xy, sigma in destination texels, source texels per destination texel)
//   params1 = (destination texel -> source texel scale, source valid extent in texels xy, unused)
float4 blur_pass_fragment(float4 position : SV_Position) : SV_Target {
  float2 direction = params0.xy;
  float sigma = max(params0.z, 0.5);
  float stride = params0.w;
  float scale = params1.x;
  float2 valid = params1.yz;
  int radius = int(ceil(sigma * 3.0));
  float2 base = position.xy * scale;
  float4 sum = float4(0.0, 0.0, 0.0, 0.0);
  float total = 0.0;
  for (int k = -radius; k <= radius; k++) {
    float wgt = exp(-float(k * k) / (2.0 * sigma * sigma));
    float2 q = clamp(base + float(k) * stride * direction, float2(0.5, 0.5), valid - 0.5);
    sum += tex.SampleLevel(samp, q / texture_size, 0.0) * wgt;
    total += wgt;
  }
  return sum / total;
}

struct BackdropBlur {
  uint order;
  float blur_radius;
  Bounds bounds;
  Bounds content_mask;
  Corners corner_radii;
};
StructuredBuffer<BackdropBlur> backdrop_blurs : register(t0);

struct BlurVarying {
  float4 position : SV_Position;
  float4 clip : SV_ClipDistance0;
  nointerpolation uint id : TEXCOORD0;
};

BlurVarying backdrop_blur_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
  uint id = instance_id + first_instance;
  float2 unit_vertex = UNIT_VERTICES[vertex_id];
  BackdropBlur blur = backdrop_blurs[id];
  float2 p = unit_position(unit_vertex, blur.bounds);
  BlurVarying o;
  o.position = to_device_position(p);
  o.clip = distance_from_clip_rect(p, blur.content_mask);
  o.id = id;
  return o;
}

//   params0.x = downsample factor, params0.yz = valid blurred extent in texels.
float4 backdrop_blur_fragment(BlurVarying input) : SV_Target {
  BackdropBlur blur = backdrop_blurs[input.id];
  if (quad_sdf(input.position.xy, blur.bounds, blur.corner_radii) > 0.0) discard;
  float2 q = clamp(input.position.xy / params0.x, float2(0.5, 0.5), params0.yz - 0.5);
  return tex.SampleLevel(samp, q / texture_size, 0.0);
}
