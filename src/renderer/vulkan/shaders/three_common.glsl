// zpui.three spike: shared 3D definitions. Mirrors src/three/scene3d.zig.
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

struct Vertex3D { vec3 pos; vec3 normal; };
struct FrameUniforms { mat4 view_proj; vec4 camera_pos; vec4 light_dir; vec4 light_color; vec4 ambient; };
struct DrawData { mat4 model; vec4 base_color; vec4 params; };

layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Vertices3D { Vertex3D v[]; };
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Indices3D { uint i[]; };
layout(buffer_reference, scalar, buffer_reference_align = 16) readonly buffer FrameRef { FrameUniforms f; };
layout(buffer_reference, scalar, buffer_reference_align = 16) readonly buffer DrawRef { DrawData d; };

layout(push_constant, scalar) uniform Push3D {
  Vertices3D vertices;
  Indices3D indices;
  FrameRef frame;
  DrawRef draw;
} pc;
