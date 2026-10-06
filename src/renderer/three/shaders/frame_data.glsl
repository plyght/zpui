// Per-viewport constants; mirrors `gpu.FrameData` in src/three/gpu.zig.
struct FrameData {
  mat4 view_proj;
  mat4 view;
  mat4 proj;
  mat4 inv_proj;
  mat4 light_view_proj;
  vec4 camera_pos;
  vec4 sun_dir;
  vec4 sun_color;
  vec4 sky;
  vec4 ground;
  vec4 fog;
  vec4 shadow;
  vec4 viewport;
  vec4 env;
  vec4 sh[9];
};
