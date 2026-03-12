#include <metal_stdlib>
using namespace metal;

// Simple BGRA passthrough shader — samples a BGRA texture and renders it directly.
// Used when source is ScreenCaptureKit BGRA (not NV12).

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vs_passthrough(uint vertex_id [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    VertexOut out;
    out.position = float4(positions[vertex_id], 0.0, 1.0);
    float2 raw_uv = (positions[vertex_id] + 1.0) * 0.5;
    out.uv = float2(raw_uv.x, 1.0 - raw_uv.y);
    return out;
}

fragment float4 fs_passthrough(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return source.sample(s, in.uv);
}
