#version 450
#include "quad.glsl"

layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_border_color;
layout(location = 2) flat in vec4 v_solid;
layout(location = 3) flat in vec4 v_color0;
layout(location = 4) flat in vec4 v_color1;
layout(location = 0) out vec4 out_color;

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
  return clamp(antialias_threshold - signed_distance / dash_velocity, 0.0, 1.0);
}

float quarter_ellipse_sdf(vec2 point, vec2 radii) {
  vec2 circle_vec = point / radii;
  float unit_circle_sdf = length(circle_vec) - 1.0;
  return unit_circle_sdf * (radii.x + radii.y) * -0.5;
}

// Port of Metal `quad_fragment` (M:101-404). Edge fade is applied once to
// the fill and once to the border, as on Metal.
void main() {
  Quad quad = pc.instances.items[v_id];
  vec2 frag = gl_FragCoord.xy;
  vec4 background_color = fill_color(quad.background, frag, quad.bounds, v_solid, v_color0, v_color1);
  float edge_fade = edge_fade_alpha(frag, quad.fade);
  background_color.a *= edge_fade;

  Corners r = quad.corner_radii;
  Edges bw = quad.border_widths;
  bool unrounded = r.top_left == 0.0 && r.bottom_left == 0.0 && r.top_right == 0.0 && r.bottom_right == 0.0;
  if (bw.top == 0.0 && bw.left == 0.0 && bw.right == 0.0 && bw.bottom == 0.0 && unrounded) {
    out_color = background_color;
    return;
  }

  vec2 size = quad.bounds.size;
  vec2 half_size = size / 2.0;
  vec2 point = frag - quad.bounds.origin;
  vec2 center_to_point = point - half_size;
  const float antialias_threshold = 0.5;
  float corner_radius = pick_corner_radius(center_to_point, r);
  vec2 border = vec2(center_to_point.x < 0.0 ? bw.left : bw.right,
                     center_to_point.y < 0.0 ? bw.top : bw.bottom);
  vec2 reduced_border = vec2(border.x == 0.0 ? -antialias_threshold : border.x,
                             border.y == 0.0 ? -antialias_threshold : border.y);
  vec2 corner_to_point = abs(center_to_point) - half_size;
  vec2 corner_center_to_point = corner_to_point + corner_radius;
  bool is_near_rounded_corner = corner_center_to_point.x >= 0.0 && corner_center_to_point.y >= 0.0;
  vec2 straight_border_inner_corner_to_point = corner_to_point + reduced_border;
  bool is_beyond_inner_straight_border =
      straight_border_inner_corner_to_point.x > 0.0 || straight_border_inner_corner_to_point.y > 0.0;
  bool is_within_inner_straight_border =
      straight_border_inner_corner_to_point.x < -antialias_threshold &&
      straight_border_inner_corner_to_point.y < -antialias_threshold;
  if (is_within_inner_straight_border && !is_near_rounded_corner) {
    out_color = background_color;
    return;
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
    vec2 ellipse_radii = max(vec2(0.0), vec2(corner_radius) - reduced_border);
    inner_sdf = quarter_ellipse_sdf(corner_center_to_point, ellipse_radii);
  }

  float border_sdf = max(inner_sdf, outer_sdf);
  vec4 color = background_color;
  if (border_sdf < antialias_threshold) {
    vec4 border_color = v_border_color;
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
        vec2 dashed_border = vec2(max(bw.bottom, bw.top), max(bw.right, bw.left));
        float border_width = is_horizontal ? dashed_border.x : dashed_border.y;
        dash_velocity = dv_numerator / border_width;
        t = (is_horizontal ? point.x : point.y) * dash_velocity;
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
          float radians = atan(corner_center_to_point.y, corner_center_to_point.x);
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
              t = (point.x - r_tl) * dash_velocity;
            } else {
              dash_velocity = dv_b;
              t = upto_bl - (point.x - r_bl) * dash_velocity;
            }
          } else {
            if (center_to_point.x < 0.0) {
              dash_velocity = dv_l;
              t = upto_tl - (point.y - r_tl) * dash_velocity;
            } else {
              dash_velocity = dv_r;
              t = upto_r + (point.y - r_tr) * dash_velocity;
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

    vec4 blended_border = over(background_color, border_color);
    color = mix(background_color, blended_border, clamp(antialias_threshold - inner_sdf, 0.0, 1.0));
  }

  out_color = color * vec4(1.0, 1.0, 1.0, clamp(antialias_threshold - outer_sdf, 0.0, 1.0));
}
