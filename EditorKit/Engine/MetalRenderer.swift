@preconcurrency import Metal
@preconcurrency import MetalPerformanceShaders
import CoreVideo
import CoreGraphics
import simd

struct LayerUniforms {
    var exposure: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    var warmth: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var vignette: Float = 0
    var sharpen: Float = 0
    var opacity: Float = 1
    var lutIntensity: Float = 0
    var brightness: Float = 1
    var blurRadius: Float = 0
    var wipeProgress: Float = -1
    var glitch: Float = 0
    var maskMode: Float = 0
    var time: Float = 0
    var maskColor: SIMD4<Float> = .zero
    var texelSize: SIMD2<Float> = .zero
    var canvasSize: SIMD2<Float> = .zero
}

public enum RendererError: Error { case noDevice, pipeline, texture }

/// Shared GPU state: pipelines, texture caches, LUTs and overlay textures.
///
/// All GPU work for preview and export goes through one command queue. Frames
/// are wrapped as Metal textures straight from their CVPixelBuffers (IOSurface
/// backed), so video data is never copied through the CPU.
public final class MetalRenderer: @unchecked Sendable {
    public static let shared: MetalRenderer? = try? MetalRenderer()

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let layerPipeline: MTLRenderPipelineState
    let overlayPipeline: MTLRenderPipelineState
    let solidPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var lutTextures: [String: MTLTexture] = [:]
    private var imageTextures: [ObjectIdentifier: (CGImage, MTLTexture)] = [:]
    private var scratch: [String: MTLTexture] = [:]
    let dummy2D: MTLTexture
    let dummy3D: MTLTexture

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        self.device = device
        self.queue = queue
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalRenderer.self))

        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "quad_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = true
            // Premultiplied "over".
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        layerPipeline = try pipeline("layer_fragment")
        overlayPipeline = try pipeline("overlay_fragment")
        solidPipeline = try pipeline("solid_fragment")
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        let d2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let t2 = device.makeTexture(descriptor: d2) else { throw RendererError.texture }
        var white: UInt32 = 0xFFFF_FFFF
        t2.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        dummy2D = t2
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D
        d3.pixelFormat = .rgba8Unorm
        d3.width = 1; d3.height = 1; d3.depth = 1
        guard let t3 = device.makeTexture(descriptor: d3) else { throw RendererError.texture }
        dummy3D = t3
    }

    // MARK: Textures

    /// Wraps a pixel buffer as a Metal texture without copying.
    func texture(from buffer: CVPixelBuffer, plane: Int = 0, format: MTLPixelFormat = .bgra8Unorm) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane) > 0 ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane) > 0 ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &cv)
        guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

    func lutTexture(for filterID: String) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let t = lutTextures[filterID] { return t }
        guard let preset = FilterLibrary.preset(filterID) else { return nil }
        let size = FilterLibrary.lutSize
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = size; d.height = size; d.depth = size
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        var data = FilterLibrary.lutData(for: preset, size: size)
        data.withUnsafeMutableBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: size * 16, bytesPerImage: size * size * 16)
        }
        lutTextures[filterID] = tex
        return tex
    }

    /// Uploads (and caches by identity) a CGImage as a premultiplied BGRA texture.
    func texture(for image: CGImage) -> MTLTexture? {
        let key = ObjectIdentifier(image)
        lock.lock()
        if let (img, tex) = imageTextures[key], img === image { lock.unlock(); return tex }
        lock.unlock()
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        lock.lock()
        if imageTextures.count > 64 { imageTextures.removeAll() }
        imageTextures[key] = (image, tex)
        lock.unlock()
        return tex
    }

    /// Reusable intermediate textures (blur buffers) keyed by purpose and size.
    func scratchTexture(_ name: String, width: Int, height: Int) -> MTLTexture? {
        let key = "\(name)-\(width)x\(height)"
        lock.lock(); defer { lock.unlock() }
        if let t = scratch[key] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        scratch[key] = t
        return t
    }

    func purgeCaches() {
        lock.lock(); defer { lock.unlock() }
        imageTextures.removeAll()
        scratch.removeAll()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    // MARK: Drawing helpers

    func drawQuad(_ encoder: MTLRenderCommandEncoder, _ vertices: [QuadVertex]) {
        guard vertices.count == 4 else { return }
        var v = vertices
        encoder.setVertexBytes(&v, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    func drawLayer(_ encoder: MTLRenderCommandEncoder, vertices: [QuadVertex], source: MTLTexture,
                   uniforms: LayerUniforms, lut: MTLTexture?, mask: MTLTexture?, blurred: MTLTexture?) {
        encoder.setRenderPipelineState(layerPipeline)
        var u = uniforms
        u.texelSize = SIMD2(1 / Float(source.width), 1 / Float(source.height))
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(lut ?? dummy3D, index: 1)
        encoder.setFragmentTexture(mask ?? dummy2D, index: 2)
        encoder.setFragmentTexture(blurred ?? dummy2D, index: 3)
        encoder.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        drawQuad(encoder, vertices)
    }

    func drawOverlay(_ encoder: MTLRenderCommandEncoder, vertices: [QuadVertex], texture: MTLTexture, opacity: Float) {
        encoder.setRenderPipelineState(overlayPipeline)
        var o = opacity
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&o, length: MemoryLayout<Float>.stride, index: 0)
        drawQuad(encoder, vertices)
    }

    func drawSolid(_ encoder: MTLRenderCommandEncoder, color: SIMD4<Float>) {
        encoder.setRenderPipelineState(solidPipeline)
        var c = color
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        drawQuad(encoder, LayerGeometry.fullscreen())
    }

    /// Gaussian blur (MPS) from `source` into `destination`.
    func blur(_ commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture, sigma: Float) {
        let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        kernel.edgeMode = .clamp
        kernel.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
    }
}
