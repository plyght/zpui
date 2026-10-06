#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct PositionsBuf
{
    float v[1];
};

struct NormalsBuf
{
    float v[1];
};

struct Instance
{
    float4x4 model;
    float4 tint;
    uint pick_id;
    uint palette_row;
    uint user;
    uint pad;
};

struct Instance_1
{
    float4x4 model;
    float4 tint;
    uint pick_id;
    uint palette_row;
    uint user;
    uint pad;
};

struct InstancesBuf
{
    Instance_1 v[1];
};

struct FrameData
{
    float4x4 view_proj;
    float4x4 view;
    float4x4 proj;
    float4x4 inv_proj;
    float4x4 light_view_proj;
    float4 camera_pos;
    float4 sun_dir;
    float4 sun_color;
    float4 sky;
    float4 ground;
    float4 fog;
    float4 shadow;
    float4 viewport;
    float4 env;
    float4 sh[9];
};

struct FrameBuf
{
    FrameData f;
};

struct UvsBuf
{
    float v[1];
};

struct ColorsBuf
{
    uint v[1];
};

struct IdsBuf
{
    uint v[1];
};

struct DrawData
{
    float4 base_color;
    float4 emissive;
    float4 pbr;
    float4 toon;
    float4 detail;
    float4 outline_color;
    float4 outline;
    float4 highlight_color;
    uint4 flags;
};

struct DrawBuf
{
    DrawData d;
};

struct shadow_vert_out
{
    float4 gl_Position [[position]];
};

static inline __attribute__((always_inline))
float3 read_vec3(thread const uint& base_index, thread const uint& which, const device PositionsBuf& b_positions, const device NormalsBuf& b_normals)
{
    if (which == 0u)
    {
        return float3(b_positions.v[base_index * 3u], b_positions.v[(base_index * 3u) + 1u], b_positions.v[(base_index * 3u) + 2u]);
    }
    return float3(b_normals.v[base_index * 3u], b_normals.v[(base_index * 3u) + 1u], b_normals.v[(base_index * 3u) + 2u]);
}

vertex shadow_vert_out shadow_vert(const device PositionsBuf& b_positions [[buffer(0)]], const device NormalsBuf& b_normals [[buffer(1)]], const device InstancesBuf& b_instances [[buffer(5)]], const device FrameBuf& b_frame [[buffer(6)]], uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]])
{
    shadow_vert_out out = {};
    uint vi = uint(int(gl_VertexIndex));
    Instance _88;
    _88.model = b_instances.v[int(gl_InstanceIndex)].model;
    _88.tint = b_instances.v[int(gl_InstanceIndex)].tint;
    _88.pick_id = b_instances.v[int(gl_InstanceIndex)].pick_id;
    _88.palette_row = b_instances.v[int(gl_InstanceIndex)].palette_row;
    _88.user = b_instances.v[int(gl_InstanceIndex)].user;
    _88.pad = b_instances.v[int(gl_InstanceIndex)].pad;
    Instance inst = _88;
    uint param = vi;
    uint param_1 = 0u;
    out.gl_Position = b_frame.f.light_view_proj * (inst.model * float4(read_vec3(param, param_1, b_positions, b_normals), 1.0));
    out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal
    return out;
}

