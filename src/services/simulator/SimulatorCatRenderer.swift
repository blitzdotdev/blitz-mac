import Foundation
import Metal
import MetalKit
import os

private let catLogger = Logger(subsystem: "com.blitz.macos", category: "SimulatorCatRenderer")

// MARK: - Stage Background Shader (fullscreen quad)

private let stageShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct StageUniforms {
    float2 viewSize;
    float4 phoneRect;
    float time;
    uint phoneVisible;
    uint laserDotCount;
    uint laserTrailCount;
};

struct LaserDot {
    float2 position;
    float age;       // 0 = just appeared, 1 = fully faded
    float _pad;
};

struct LaserTrail {
    float2 from;
    float2 to;
    float age;
    float _pad0;
    float _pad1;
    float _pad2;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vs_stage(uint vertex_id [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(positions[vertex_id], 0.0, 1.0);
    out.uv = (positions[vertex_id] + 1.0) * 0.5;
    return out;
}

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 34.45);
    return fract(p.x * p.y);
}

float phoneHalo(float2 pixel, float4 phoneRect) {
    float2 center = float2(phoneRect.x + phoneRect.z * 0.5, phoneRect.y + phoneRect.w * 0.5);
    float2 d = abs(pixel - center) - float2(phoneRect.z, phoneRect.w) * 0.5;
    float outside = length(max(d, float2(0.0)));
    return 1.0 - smoothstep(14.0, 82.0, outside);
}

float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

fragment float4 fs_stage(
    VertexOut in [[stage_in]],
    constant StageUniforms &stage [[buffer(0)]],
    constant LaserDot *dots [[buffer(1)]],
    constant LaserTrail *trails [[buffer(2)]]
) {
    float2 pixel = in.uv * stage.viewSize;
    float2 uv = pixel / max(stage.viewSize, 1.0);

    // Dark stage background with subtle texture
    float3 baseA = float3(0.17, 0.19, 0.22);
    float3 baseB = float3(0.11, 0.12, 0.14);
    float3 color = mix(baseA, baseB, uv.y);

    float diagonal = 0.5 + 0.5 * sin((uv.x + uv.y) * 10.0 + stage.time * 0.55);
    color += 0.03 * diagonal;

    float grid = step(0.93, fract(uv.x * 18.0)) + step(0.93, fract(uv.y * 12.0));
    color += grid * 0.018;

    float noise = hash21(floor(pixel / 12.0));
    color += (noise - 0.5) * 0.018;

    if (stage.phoneVisible == 1) {
        float glow = phoneHalo(pixel, stage.phoneRect);
        color = mix(color, float3(0.24, 0.26, 0.30), glow * 0.4);
    }

    // Laser trails — thin neon plasma lines
    for (uint i = 0; i < stage.laserTrailCount; ++i) {
        float dist = sdSegment(pixel, trails[i].from, trails[i].to);
        float age = trails[i].age;
        float fade = max(0.0, 1.0 - age);

        // Thin bright core
        float core = exp(-dist * dist / 3.0) * fade;
        // Wider soft glow
        float glow = exp(-dist * dist / 80.0) * fade * 0.5;
        // Outer halo
        float halo = exp(-dist * dist / 400.0) * fade * 0.2;

        float3 laserColor = float3(1.0, 0.15, 0.12);  // red neon
        float3 coreColor = float3(1.0, 0.6, 0.55);     // hot white-pink core

        color += coreColor * core + laserColor * glow + laserColor * 0.5 * halo;
    }

    // Laser dots — glowing neon points
    for (uint i = 0; i < stage.laserDotCount; ++i) {
        float dist = length(pixel - dots[i].position);
        float age = dots[i].age;
        float fade = max(0.0, 1.0 - age);
        float pulse = 1.0 + 0.3 * sin(stage.time * 18.0 + float(i) * 2.3);

        // Tight bright core
        float core = exp(-dist * dist / 6.0) * fade * pulse;
        // Medium glow
        float glow = exp(-dist * dist / 120.0) * fade * 0.6;
        // Wide halo
        float halo = exp(-dist * dist / 800.0) * fade * 0.25;

        float3 dotCore = float3(1.0, 0.85, 0.82);
        float3 dotColor = float3(1.0, 0.1, 0.08);

        color += dotCore * core + dotColor * glow + dotColor * 0.4 * halo;
    }

    float vignette = smoothstep(1.16, 0.28, distance(uv, float2(0.5)));
    color *= mix(0.86, 1.06, vignette);

    return float4(saturate(color), 1.0);
}
"""

// MARK: - Voxel Cat Shader (3D geometry)

private let voxelShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VoxelUniforms {
    float4x4 viewProjection;
    float3 lightDir;
    float ambientStrength;
    float2 viewSize;
    float _pad0;
    float _pad1;
};

struct VoxelVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct VoxelVertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float4 color;
    float3 worldPosition;
};

vertex VoxelVertexOut vs_voxel(
    VoxelVertexIn in [[stage_in]],
    constant VoxelUniforms &uniforms [[buffer(1)]]
) {
    VoxelVertexOut out;
    out.position = uniforms.viewProjection * float4(in.position, 1.0);
    out.worldNormal = normalize(in.normal);
    out.color = in.color;
    out.worldPosition = in.position;
    return out;
}

fragment float4 fs_voxel(
    VoxelVertexOut in [[stage_in]],
    constant VoxelUniforms &uniforms [[buffer(1)]]
) {
    float3 normal = normalize(in.worldNormal);
    float3 lightDir = normalize(uniforms.lightDir);

    // Directional light + ambient
    float ndotl = max(dot(normal, lightDir), 0.0);
    float lighting = uniforms.ambientStrength + (1.0 - uniforms.ambientStrength) * ndotl;

    // Slight rim highlight for silhouette pop
    float rim = 1.0 - abs(normal.y);
    lighting += rim * 0.06;

    float3 color = in.color.rgb * lighting;

    // Dark outline effect: darken edges based on face normal vs view
    // This gives that Minecraft block-edge definition
    float edgeDarken = smoothstep(0.0, 0.15, abs(normal.y)) * 0.12;
    color *= (1.0 - edgeDarken * 0.5);

    return float4(saturate(color), in.color.a);
}
"""

// MARK: - Renderer

final class SimulatorCatRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Stage pipeline (background + laser effects)
    private let stagePipeline: MTLRenderPipelineState

    // Voxel pipeline (3D cat)
    private let voxelPipeline: MTLRenderPipelineState
    private let voxelVertexDescriptor: MTLVertexDescriptor
    private let depthStencilState: MTLDepthStencilState

    // Stage uniforms
    private struct StageUniforms {
        var viewSize: SIMD2<Float>
        var phoneRect: SIMD4<Float>
        var time: Float
        var phoneVisible: UInt32
        var laserDotCount: UInt32
        var laserTrailCount: UInt32
    }

    private struct LaserDotUniform {
        var position: SIMD2<Float>
        var age: Float
        var pad: Float = 0
    }

    private struct LaserTrailUniform {
        var from: SIMD2<Float>
        var to: SIMD2<Float>
        var age: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    // Voxel uniforms
    private struct VoxelUniforms {
        var viewProjection: matrix_float4x4
        var lightDir: SIMD3<Float>
        var ambientStrength: Float
        var viewSize: SIMD2<Float>
        var pad0: Float = 0
        var pad1: Float = 0
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderer.RendererError.noMetalDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRenderer.RendererError.noCommandQueue
        }

        // Compile stage shaders
        let stageLibrary: MTLLibrary
        do {
            stageLibrary = try device.makeLibrary(source: stageShaderSource, options: nil)
        } catch {
            catLogger.error("Stage shader compile failed: \(error.localizedDescription)")
            throw MetalRenderer.RendererError.shaderCompileFailed(error.localizedDescription)
        }

        let stageDesc = MTLRenderPipelineDescriptor()
        stageDesc.vertexFunction = stageLibrary.makeFunction(name: "vs_stage")
        stageDesc.fragmentFunction = stageLibrary.makeFunction(name: "fs_stage")
        stageDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        stageDesc.depthAttachmentPixelFormat = .depth32Float
        stagePipeline = try device.makeRenderPipelineState(descriptor: stageDesc)

        // Compile voxel shaders
        let voxelLibrary: MTLLibrary
        do {
            voxelLibrary = try device.makeLibrary(source: voxelShaderSource, options: nil)
        } catch {
            catLogger.error("Voxel shader compile failed: \(error.localizedDescription)")
            throw MetalRenderer.RendererError.shaderCompileFailed(error.localizedDescription)
        }

        // Vertex descriptor for VoxelVertex
        let vertexDesc = MTLVertexDescriptor()
        // position: float3 at offset 0
        vertexDesc.attributes[0].format = .float3
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        // normal: float3 at offset 12
        vertexDesc.attributes[1].format = .float3
        vertexDesc.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDesc.attributes[1].bufferIndex = 0
        // color: float4 at offset 24
        vertexDesc.attributes[2].format = .float4
        vertexDesc.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        vertexDesc.attributes[2].bufferIndex = 0
        // stride
        vertexDesc.layouts[0].stride = MemoryLayout<VoxelVertex>.stride
        vertexDesc.layouts[0].stepFunction = .perVertex
        voxelVertexDescriptor = vertexDesc

        let voxelDesc = MTLRenderPipelineDescriptor()
        voxelDesc.vertexFunction = voxelLibrary.makeFunction(name: "vs_voxel")
        voxelDesc.fragmentFunction = voxelLibrary.makeFunction(name: "fs_voxel")
        voxelDesc.vertexDescriptor = vertexDesc
        voxelDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        voxelDesc.depthAttachmentPixelFormat = .depth32Float
        voxelPipeline = try device.makeRenderPipelineState(descriptor: voxelDesc)

        // Depth stencil for voxel rendering
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        guard let dsState = device.makeDepthStencilState(descriptor: dsDesc) else {
            throw MetalRenderer.RendererError.noCommandQueue
        }
        depthStencilState = dsState

        self.device = device
        self.commandQueue = commandQueue
    }

    var metalDevice: MTLDevice { device }

    func render(
        snapshot: SimulatorCatSceneModel.Snapshot,
        to drawable: CAMetalDrawable,
        renderPassDescriptor rpd: MTLRenderPassDescriptor
    ) {
        // MTKView's currentRenderPassDescriptor already has color + depth attachments
        // configured from depthStencilPixelFormat. Just use it directly.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // --- Pass 1: Stage background + laser effects ---
        encoder.setRenderPipelineState(stagePipeline)

        var stageU = StageUniforms(
            viewSize: SIMD2(Float(snapshot.stageSize.width), Float(snapshot.stageSize.height)),
            phoneRect: SIMD4(
                Float(snapshot.phoneRect.minX), Float(snapshot.phoneRect.minY),
                Float(snapshot.phoneRect.width), Float(snapshot.phoneRect.height)
            ),
            time: snapshot.time,
            phoneVisible: snapshot.phoneVisible ? 1 : 0,
            laserDotCount: UInt32(snapshot.laserDots.count),
            laserTrailCount: UInt32(snapshot.laserTrails.count)
        )
        encoder.setFragmentBytes(&stageU, length: MemoryLayout<StageUniforms>.stride, index: 0)

        // Laser dots
        var dotUniforms = snapshot.laserDots.map { dot in
            LaserDotUniform(
                position: SIMD2(Float(dot.stagePosition.x), Float(dot.stagePosition.y)),
                age: Float(Double(snapshot.time) - dot.startTime) / Float(0.8)
            )
        }
        if dotUniforms.isEmpty {
            dotUniforms.append(LaserDotUniform(position: .zero, age: 1))
        }
        encoder.setFragmentBytes(&dotUniforms, length: MemoryLayout<LaserDotUniform>.stride * dotUniforms.count, index: 1)

        // Laser trails
        var trailUniforms = snapshot.laserTrails.map { trail in
            LaserTrailUniform(
                from: SIMD2(Float(trail.fromStage.x), Float(trail.fromStage.y)),
                to: SIMD2(Float(trail.toStage.x), Float(trail.toStage.y)),
                age: Float(Double(snapshot.time) - trail.startTime) / Float(1.2)
            )
        }
        if trailUniforms.isEmpty {
            trailUniforms.append(LaserTrailUniform(from: .zero, to: .zero, age: 1))
        }
        encoder.setFragmentBytes(&trailUniforms, length: MemoryLayout<LaserTrailUniform>.stride * trailUniforms.count, index: 2)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // --- Pass 2: Voxel cat ---
        if !snapshot.catVertices.isEmpty {
            encoder.setRenderPipelineState(voxelPipeline)
            encoder.setDepthStencilState(depthStencilState)

            // Build oblique top-down projection
            // World: X=right, Y=up, Z=down-on-screen
            // Camera looks from above at ~35° from vertical
            let viewProj = makeObliqueProjection(
                stageWidth: Float(snapshot.stageSize.width),
                stageHeight: Float(snapshot.stageSize.height)
            )

            var voxelU = VoxelUniforms(
                viewProjection: viewProj,
                lightDir: normalize(SIMD3<Float>(0.3, 0.85, -0.4)),  // light from upper-right-front
                ambientStrength: 0.42,
                viewSize: SIMD2(Float(snapshot.stageSize.width), Float(snapshot.stageSize.height))
            )
            encoder.setVertexBytes(&voxelU, length: MemoryLayout<VoxelUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&voxelU, length: MemoryLayout<VoxelUniforms>.stride, index: 1)

            // Upload vertex data
            let vertexData = snapshot.catVertices
            let bufferSize = MemoryLayout<VoxelVertex>.stride * vertexData.count
            encoder.setVertexBytes(vertexData, length: bufferSize, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Oblique Projection

    /// Creates a view-projection matrix mapping world coords to Metal NDC on macOS.
    ///
    /// macOS Metal convention: NDC Y=-1 is the top of the screen, Y=+1 is the bottom.
    /// (CAMetalLayer presents texture row 0 at the top of the window.)
    ///
    /// World coords: X=right, Y=up (perpendicular to stage), Z=down (matches SwiftUI Y).
    /// A ground-plane point (x, 0, z) maps to the same screen pixel as phoneRect point (x, z).
    /// Height (y>0) shifts pixels upward (toward NDC -1).
    private func makeObliqueProjection(stageWidth w: Float, stageHeight h: Float) -> matrix_float4x4 {
        let obliqueK: Float = 0.55
        let maxDepth: Float = max(w, h) * 2

        // ndcX = 2x/w - 1              (left=-1, right=+1)
        // ndcY = 2z/h - 1 - 2ky/h      (z=0 → -1=top, z=h → +1=bottom, y>0 → moves to top)
        // ndcZ = z/D - ky/D + 0.5       (depth: higher y = closer, larger z = farther)
        // ndcW = 1

        return matrix_float4x4(columns: (
            SIMD4<Float>(2.0 / w,    0,                       0,                   0),
            SIMD4<Float>(0,         -2.0 * obliqueK / h,     -obliqueK / maxDepth,  0),
            SIMD4<Float>(0,          2.0 / h,                 1.0 / maxDepth,        0),
            SIMD4<Float>(-1,        -1,                       0.5,                   1)
        ))
    }
}
