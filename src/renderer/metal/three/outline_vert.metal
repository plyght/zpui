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

struct outline_vert_out
{
    float v_view_depth [[user(locn0)]];
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

static inline __attribute__((always_inline))
float3x3 cofactor(thread const float3x3& m)
{
    return float3x3(float3(cross(m[1], m[2])), float3(cross(m[2], m[0])), float3(cross(m[0], m[1])));
}

vertex outline_vert_out outline_vert(const device PositionsBuf& b_positions [[buffer(0)]], const device NormalsBuf& b_normals [[buffer(1)]], const device InstancesBuf& b_instances [[buffer(5)]], const device FrameBuf& b_frame [[buffer(6)]], const device DrawBuf& b_draw [[buffer(7)]], uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]])
{
    outline_vert_out out = {};
    uint vi = uint(int(gl_VertexIndex));
    Instance _129;
    _129.model = b_instances.v[int(gl_InstanceIndex)].model;
    _129.tint = b_instances.v[int(gl_InstanceIndex)].tint;
    _129.pick_id = b_instances.v[int(gl_InstanceIndex)].pick_id;
    _129.palette_row = b_instances.v[int(gl_InstanceIndex)].palette_row;
    _129.user = b_instances.v[int(gl_InstanceIndex)].user;
    _129.pad = b_instances.v[int(gl_InstanceIndex)].pad;
    Instance inst = _129;
    uint flags = ((device uint*)&b_draw.d.flags)[0u];
    uint param = vi;
    uint param_1 = 0u;
    float4 world = inst.model * float4(read_vec3(param, param_1, b_positions, b_normals), 1.0);
    float3 _158;
    if ((flags & 1u) != 0u)
    {
        float3x3 param_2 = float3x3(inst.model[0].xyz, inst.model[1].xyz, inst.model[2].xyz);
        uint param_3 = vi;
        uint param_4 = 1u;
        _158 = fast::normalize(cofactor(param_2) * read_vec3(param_3, param_4, b_positions, b_normals));
    }
    else
    {
        _158 = float3(0.0);
    }
    float3 n = _158;
    float width = ((device float*)&b_draw.d.outline)[0u];
    if ((flags & 2048u) == 0u)
    {
        float4 _195 = world;
        float3 _197 = _195.xyz + (n * width);
        world.x = _197.x;
        world.y = _197.y;
        world.z = _197.z;
    }
    float4 clip = b_frame.f.view_proj * world;
    if ((flags & 2048u) != 0u)
    {
        float2 dir = (b_frame.f.view_proj * float4(n, 0.0)).xy;
        float len = length(dir);
        if (len > 9.9999999747524270787835121154785e-07)
        {
            float _256 = clip.w;
            float4 _258 = clip;
            float2 _260 = _258.xy + (((((dir / float2(len)) * width) * 2.0) * b_frame.f.viewport.zw) * _256);
            clip.x = _260.x;
            clip.y = _260.y;
        }
    }
    out.v_view_depth = -(b_frame.f.view * world).z;
    out.gl_Position = clip;
    out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal
    return out;
}

