import Foundation
import Metal
import MetalKit
import CoreVideo
import os

private let logger = Logger(subsystem: "com.blitz.macos", category: "MetalRenderer")

// Shader source compiled at runtime — avoids Bundle.module resource path issues in .app bundles
private let passthroughShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CropUniforms {
    float4 cropRect; // x, y, w, h in UV space (0-1)
};

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
    texture2d<float> source [[texture(0)]],
    constant CropUniforms &crop [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Map output UV (0-1) to the crop region of the source texture
    float2 srcUV = float2(
        crop.cropRect.x + in.uv.x * crop.cropRect.z,
        crop.cropRect.y + in.uv.y * crop.cropRect.w
    );
    return source.sample(s, srcUV);
}
"""

private let cursorShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CursorUniforms {
    float2 position;
    float2 output_size;
    float  radius;
    float  opacity;
    float  is_click;
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
    float effective_radius = u.radius * mix(1.0, 0.7, u.is_click);
    float aa = 1.5;
    float alpha = 1.0 - smoothstep(effective_radius - aa, effective_radius + aa, dist);
    if (alpha < 0.001) { discard_fragment(); }
    float border_dist = abs(dist - effective_radius + 1.5);
    float border = 1.0 - smoothstep(0.0, 2.0, border_dist);
    float3 color = mix(float3(1.0), float3(0.2), border * 0.3);
    return float4(color, alpha * u.opacity);
}
"""

/// Metal rendering pipeline for simulator/device frames
final class MetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var passthroughPipeline: MTLRenderPipelineState
    private var cursorPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }

        self.device = device
        self.commandQueue = queue

        logger.info("Metal device: \(device.name)")

        // Compile shaders from source at runtime
        let passthroughLib: MTLLibrary
        do {
            passthroughLib = try device.makeLibrary(source: passthroughShaderSource, options: nil)
        } catch {
            logger.error("Failed to compile passthrough shader: \(error.localizedDescription)")
            throw RendererError.shaderCompileFailed(error.localizedDescription)
        }

        let cursorLib: MTLLibrary
        do {
            cursorLib = try device.makeLibrary(source: cursorShaderSource, options: nil)
        } catch {
            logger.error("Failed to compile cursor shader: \(error.localizedDescription)")
            throw RendererError.shaderCompileFailed(error.localizedDescription)
        }

        // Passthrough pipeline (BGRA texture → screen)
        let passDesc = MTLRenderPipelineDescriptor()
        passDesc.vertexFunction = passthroughLib.makeFunction(name: "vs_passthrough")
        passDesc.fragmentFunction = passthroughLib.makeFunction(name: "fs_passthrough")
        passDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        passthroughPipeline = try device.makeRenderPipelineState(descriptor: passDesc)

        // Cursor pipeline
        let cursorDesc = MTLRenderPipelineDescriptor()
        cursorDesc.vertexFunction = cursorLib.makeFunction(name: "vs_cursor")
        cursorDesc.fragmentFunction = cursorLib.makeFunction(name: "fs_cursor")
        cursorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        cursorDesc.colorAttachments[0].isBlendingEnabled = true
        cursorDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cursorDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cursorDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        cursorDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cursorPipeline = try device.makeRenderPipelineState(descriptor: cursorDesc)

        // Texture cache for zero-copy CVPixelBuffer → MTLTexture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        logger.info("Metal renderer initialized successfully")
    }

    /// Create MTLTexture from CVPixelBuffer (zero-copy via IOSurface)
    func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Render a BGRA frame to the drawable, cropping to the specified UV rect
    func renderBGRAFrame(
        pixelBuffer: CVPixelBuffer,
        to drawable: CAMetalDrawable,
        renderPassDescriptor: MTLRenderPassDescriptor,
        cropRect: (x: Double, y: Double, w: Double, h: Double) = (0, 0, 1, 1),
        cursor: CursorState? = nil
    ) {
        guard let texture = makeTexture(from: pixelBuffer),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let width = drawable.texture.width
        let height = drawable.texture.height

        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.setRenderPipelineState(passthroughPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        var cropUniforms = CropUniforms(
            cropRect: SIMD4<Float>(Float(cropRect.x), Float(cropRect.y), Float(cropRect.w), Float(cropRect.h))
        )
        encoder.setFragmentBytes(&cropUniforms, length: MemoryLayout<CropUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // Cursor overlay
        if let cursor, cursor.opacity > 0 {
            let cursorPassDesc = MTLRenderPassDescriptor()
            cursorPassDesc.colorAttachments[0].texture = drawable.texture
            cursorPassDesc.colorAttachments[0].loadAction = .load
            cursorPassDesc.colorAttachments[0].storeAction = .store

            if let cursorEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cursorPassDesc) {
                cursorEncoder.setRenderPipelineState(cursorPipeline)
                var cursorUniforms = CursorUniforms(
                    position: SIMD2<Float>(Float(cursor.x), Float(cursor.y)),
                    outputSize: SIMD2<Float>(Float(width), Float(height)),
                    radius: Float(cursor.radius),
                    opacity: Float(cursor.opacity),
                    isClick: cursor.isClick ? 1.0 : 0.0,
                    _pad: 0
                )
                cursorEncoder.setFragmentBytes(&cursorUniforms, length: MemoryLayout<CursorUniforms>.size, index: 0)
                cursorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                cursorEncoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func flushCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    enum RendererError: Error, LocalizedError {
        case noMetalDevice
        case noCommandQueue
        case noShaderLibrary
        case shaderCompileFailed(String)

        var errorDescription: String? {
            switch self {
            case .noMetalDevice: return "No Metal-capable GPU found"
            case .noCommandQueue: return "Failed to create Metal command queue"
            case .noShaderLibrary: return "Failed to load Metal shader library"
            case .shaderCompileFailed(let msg): return "Shader compile failed: \(msg)"
            }
        }
    }
}

// MARK: - Uniform Structs

struct CropUniforms {
    var cropRect: SIMD4<Float> // x, y, w, h in UV space (0-1)
}

struct CursorUniforms {
    var position: SIMD2<Float>
    var outputSize: SIMD2<Float>
    var radius: Float
    var opacity: Float
    var isClick: Float
    var _pad: Float
}

struct CursorState {
    var x: Double
    var y: Double
    var radius: Double
    var opacity: Double
    var isClick: Bool
}
