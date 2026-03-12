#include <metal_stdlib>
using namespace metal;

struct CompositeUniforms {
    float4 crop_bounds;      // [x, y, w, h] in normalized 0-1 UV space
    float2 output_size;      // output pixel dimensions
    float2 frame_size;       // source texture pixel dimensions
    float2 target_size;      // rendered content size in pixels (for corner math)
    float  padding;          // 0.0 - 0.3 normalized
    float  rounding_px;      // corner radius in pixels
    float4 bg_color_0;       // background gradient start (or solid)
    float4 bg_color_1;       // background gradient end
    float  has_wallpaper;    // 1.0 if wallpaper texture is bound, 0.0 otherwise
    float  shadow;           // 0.0 - 1.0 shadow intensity
    float2 _pad;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle (3 vertices cover the screen, no vertex buffer needed)
vertex VertexOut vs_composite(uint vertex_id [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    VertexOut out;
    out.position = float4(positions[vertex_id], 0.0, 1.0);
    // Flip Y: Metal's texture origin is top-left, clip space Y goes up
    float2 raw_uv = (positions[vertex_id] + 1.0) * 0.5;
    out.uv = float2(raw_uv.x, 1.0 - raw_uv.y);
    return out;
}

// SDF rounded rectangle
float sdf_rounded_rect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + float2(r);
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// BT.709 video-range YCbCr → RGB conversion.
float4 ycbcr_to_rgb(float y, float2 cbcr) {
    float3 yuv = float3(y, cbcr) - float3(16.0/255.0, 128.0/255.0, 128.0/255.0);
    const float3x3 mat = float3x3(
        float3(1.164,  1.164,  1.164),   // Y  → R, G, B
        float3(0.000, -0.213,  2.112),   // Cb → R, G, B
        float3(1.793, -0.533,  0.000)    // Cr → R, G, B
    );
    return float4(saturate(mat * yuv), 1.0);
}

fragment float4 fs_composite(
    VertexOut in [[stage_in]],
    texture2d<float> sourceY [[texture(0)]],
    texture2d<float> sourceCbCr [[texture(1)]],
    texture2d<float> wallpaper [[texture(2)]],
    constant CompositeUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;

    // 1. Background: wallpaper texture or gradient
    float4 bg;
    if (u.has_wallpaper > 0.5) {
        bg = wallpaper.sample(s, uv);
    } else {
        bg = mix(u.bg_color_0, u.bg_color_1, uv.y);
    }

    // 2. Content area bounds (after padding)
    float2 content_min = float2(u.padding);
    float2 content_max = float2(1.0 - u.padding);

    // 3. Shadow pass
    if (u.shadow > 0.0 && u.padding > 0.0) {
        float2 pixel = uv * u.output_size;
        float2 rect_min = content_min * u.output_size;
        float2 rect_max = content_max * u.output_size;
        float2 rect_center = (rect_min + rect_max) * 0.5;
        float2 rect_half = (rect_max - rect_min) * 0.5;
        float2 p = pixel - rect_center;
        float shadow_r = u.rounding_px > 0.0 ? u.rounding_px : 0.0;

        float blur = mix(10.0, 60.0, u.shadow);
        float offset_y = mix(4.0, 20.0, u.shadow);

        float2 p_offset = p - float2(0.0, offset_y);
        float offset_dist = sdf_rounded_rect(p_offset, rect_half, shadow_r);

        float shadow_alpha = 1.0 - smoothstep(-2.0, blur, offset_dist);
        shadow_alpha *= u.shadow;

        bg = mix(bg, float4(0.0, 0.0, 0.0, 1.0), shadow_alpha * 0.7);
    }

    // Outside content area → background
    if (uv.x < content_min.x || uv.x > content_max.x ||
        uv.y < content_min.y || uv.y > content_max.y) {
        return bg;
    }

    // 4. Map to content UV
    float2 content_uv = (uv - content_min) / (content_max - content_min);

    // 5. Map to source UV via crop rect
    float2 source_uv = u.crop_bounds.xy + content_uv * u.crop_bounds.zw;

    float2 texel_offset = 1.0 / u.frame_size;
    source_uv = clamp(source_uv, texel_offset, float2(1.0) - texel_offset);

    // 6. Sample NV12 source and convert YCbCr → RGB
    float y_val = sourceY.sample(s, source_uv).r;
    float2 cbcr_val = sourceCbCr.sample(s, source_uv).rg;
    float4 color = ycbcr_to_rgb(y_val, cbcr_val);

    // 7. Rounded corners
    if (u.rounding_px > 0.0) {
        float2 centered = (content_uv - float2(0.5)) * u.target_size;
        float2 half_size = u.target_size * 0.5;
        float dist = sdf_rounded_rect(centered, half_size, u.rounding_px);
        float aa_width = max(fwidth(dist), 0.5);
        float coverage = clamp(1.0 - smoothstep(0.0, aa_width, dist), 0.0, 1.0);
        color.a *= coverage;
    }

    // 8. Blend content over background
    return mix(bg, color, color.a);
}
