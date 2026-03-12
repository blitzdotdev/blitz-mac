#include <metal_stdlib>
using namespace metal;

struct CursorUniforms {
    float2 position;     // cursor center in output UV space (0-1)
    float2 output_size;  // output pixel dimensions
    float  radius;       // cursor radius in pixels
    float  opacity;      // 0-1
    float  is_click;     // 1.0 if clicking, 0.0 otherwise
    float  _pad;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vs_cursor(uint vertex_id [[vertex_id]]) {
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

fragment float4 fs_cursor(
    VertexOut in [[stage_in]],
    constant CursorUniforms &u [[buffer(0)]]
) {
    float2 pixel = in.uv * u.output_size;
    float2 cursor_pixel = u.position * u.output_size;
    float dist = length(pixel - cursor_pixel);

    // Click shrink effect (70% size during click)
    float effective_radius = u.radius * mix(1.0, 0.7, u.is_click);

    // Anti-aliased circle
    float aa = 1.5;
    float alpha = 1.0 - smoothstep(effective_radius - aa, effective_radius + aa, dist);

    if (alpha < 0.001) {
        discard_fragment();
    }

    // White cursor with slight border
    float border_dist = abs(dist - effective_radius + 1.5);
    float border = 1.0 - smoothstep(0.0, 2.0, border_dist);
    float3 color = mix(float3(1.0), float3(0.2), border * 0.3);

    return float4(color, alpha * u.opacity);
}
