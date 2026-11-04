@preconcurrency import AVFoundation
@preconcurrency import Metal
@preconcurrency import Vision
import CoreImage
import simd

/// Custom AVFoundation compositor that draws every layer of a frame (canvas
/// background, main-track clips with effects and transitions, text and
/// captions) in a single Metal command buffer.
public final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "cutline.compositor", qos: .userInteractive)
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false
    private let segmentation = SegmentationCache()
    private var overlayCache: [String: CGImage] = [:]

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            renderContext = newRenderContext
            overlayCache.removeAll()
        }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [self] in
            if cancelled {
                request.finishCancelledRequest()
                return
            }
            do {
                let frame = try render(request)
                request.finish(withComposedVideoFrame: frame)
            } catch {
                request.finish(with: error)
            }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        renderQueue.async { [self] in cancelled = false }
    }

    // MARK: Rendering

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let renderer = MetalRenderer.shared else { throw RendererError.noDevice }
        guard let output = request.renderContext.newPixelBuffer() else { throw RendererError.texture }
        guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
            return output
        }
        let scene = instruction.scene
        let time = MediaTime(request.compositionTime)
        guard let (target, targetRef) = renderer.texture(from: output) else { throw RendererError.texture }
        let canvas = CGSize(width: target.width, height: target.height)
        guard let commandBuffer = renderer.queue.makeCommandBuffer() else { throw RendererError.texture }

        // Collect per-layer inputs first (some need pre-passes: blur, segmentation).
        struct Layer {
            var info: ClipRenderInfo
            var texture: MTLTexture
            var sourceTurns: Int
            var animation: LayerAnimation
            var reframe: SIMD2<Double>?
            var mask: MTLTexture?
            var blurred: MTLTexture?
            var keepAlive: [Any]
        }
        var layers: [Layer] = []
        for index in instruction.clipIndices {
            let info = scene.clips[index]
            let local = time - info.timelineRange.start
            guard local >= .zero, local <= info.timelineRange.duration else { continue }
            var keepAlive: [Any] = []
            let texture: MTLTexture
            var pixelBuffer: CVPixelBuffer?
            var turns = 0
            if let trackID = info.trackID, let buffer = request.sourceFrame(byTrackID: trackID),
               let (tex, ref) = renderer.texture(from: buffer) {
                texture = tex
                keepAlive.append(ref)
                pixelBuffer = buffer
                turns = info.media.sourceQuarterTurns
            } else if let image = scene.stills[info.clip.id], let tex = renderer.texture(for: image) {
                texture = tex
            } else {
                continue
            }

            var animation = LayerAnimation()
            if let t = info.transitionIn, info.overlapIn > .zero, local < info.overlapIn {
                animation = LayerGeometry.transitionAnimation(t.kind, progress: local.seconds / info.overlapIn.seconds, incoming: true)
            } else if let t = info.transitionOut, info.overlapOut > .zero,
                      local > info.timelineRange.duration - info.overlapOut {
                let start = info.timelineRange.duration - info.overlapOut
                animation = LayerGeometry.transitionAnimation(t.kind, progress: (local - start).seconds / info.overlapOut.seconds, incoming: false)
            }
            let animate = scene.toggles.animationsEnabled
            if animate, let clipAnim = info.clip.animation, !clipAnim.isEmpty {
                let anim = LayerGeometry.clipAnimation(clipAnim, local: local.seconds,
                                                       duration: info.timelineRange.duration.seconds)
                animation = LayerGeometry.combine(anim, animation)
            }
            if animate, info.clip.isStill, let motion = info.clip.photoMotion, motion != .none {
                let progress = local.seconds / max(info.timelineRange.duration.seconds, 0.001)
                animation = LayerGeometry.combine(LayerGeometry.photoMotion(motion, progress: progress), animation)
            }

            let sourceTime = info.clip.sourceTime(atClipTime: local)
            let reframe = LayerGeometry.reframeCenter(info.clip.reframe, at: sourceTime)

            var mask: MTLTexture?
            var blurred: MTLTexture?
            if let replacement = info.clip.backgroundRemoval {
                let maskBuffer: CVPixelBuffer?
                if let pixelBuffer {
                    maskBuffer = segmentation.mask(for: pixelBuffer, quality: scene.quality, key: info.clip.id)
                } else if let image = scene.stills[info.clip.id] {
                    maskBuffer = segmentation.mask(for: image, key: info.clip.id)
                } else {
                    maskBuffer = nil
                }
                if let maskBuffer, let (mtex, mref) = renderer.texture(from: maskBuffer, format: .r8Unorm) {
                    mask = mtex
                    keepAlive.append(mref)
                }
                if case .blur = replacement,
                   let scratch = renderer.scratchTexture("subject-blur-\(index % 2)", width: texture.width, height: texture.height) {
                    renderer.blur(commandBuffer, source: texture, destination: scratch, sigma: Float(texture.width) / 60)
                    blurred = scratch
                }
            }
            layers.append(Layer(info: info, texture: texture, sourceTurns: turns, animation: animation,
                                reframe: reframe, mask: mask, blurred: blurred, keepAlive: keepAlive))
        }

        // Blurred canvas background from the bottom layer.
        var backgroundTexture: MTLTexture?
        if case .blur = scene.background, let bottom = layers.first {
            let bw = max(16, Int(canvas.width) / 4), bh = max(16, Int(canvas.height) / 4)
            if let small = renderer.scratchTexture("bg-small", width: bw, height: bh),
               let blurredBG = renderer.scratchTexture("bg-blur", width: bw, height: bh) {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = small
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pass.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                    let quad = LayerGeometry.quad(media: bottom.info.media, transform: bottom.info.clip.transform,
                                                  sourceTurns: bottom.sourceTurns, canvas: CGSize(width: bw, height: bh),
                                                  forceFill: true)
                    var u = LayerUniforms()
                    u.brightness = 0.8
                    u.canvasSize = SIMD2(Float(bw), Float(bh))
                    renderer.drawLayer(enc, vertices: quad, source: bottom.texture, uniforms: u, lut: nil, mask: nil, blurred: nil)
                    enc.endEncoding()
                }
                renderer.blur(commandBuffer, source: small, destination: blurredBG, sigma: Float(bw) / 18)
                backgroundTexture = blurredBG
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        if case .color(let c) = scene.background {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        } else {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.texture }

        if let backgroundTexture {
            var u = LayerUniforms()
            u.canvasSize = SIMD2(Float(canvas.width), Float(canvas.height))
            renderer.drawLayer(encoder, vertices: LayerGeometry.fullscreen(), source: backgroundTexture,
                               uniforms: u, lut: nil, mask: nil, blurred: nil)
        }

        for layer in layers {
            let clip = layer.info.clip
            let quad = LayerGeometry.quad(media: layer.info.media, transform: clip.transform, sourceTurns: layer.sourceTurns,
                                          canvas: canvas, animation: layer.animation, reframe: layer.reframe)
            var u = LayerUniforms()
            let adj = clip.adjustments
            u.exposure = Float(adj.exposure)
            u.contrast = Float(adj.contrast)
            u.saturation = Float(adj.saturation)
            u.warmth = Float(adj.warmth)
            u.highlights = Float(adj.highlights)
            u.shadows = Float(adj.shadows)
            u.vignette = Float(adj.vignette)
            u.sharpen = Float(adj.sharpen)
            u.opacity = layer.animation.opacity
            u.brightness = layer.animation.brightness
            u.blurRadius = layer.animation.blurRadius
            u.wipeProgress = layer.animation.wipeProgress
            u.glitch = layer.animation.glitch
            u.time = Float(time.seconds)
            u.canvasSize = SIMD2(Float(canvas.width), Float(canvas.height))
            var lut: MTLTexture?
            if let filter = clip.filter, filter.intensity > 0, let t = renderer.lutTexture(for: filter.filterID) {
                lut = t
                u.lutIntensity = Float(filter.intensity)
            }
            if let replacement = clip.backgroundRemoval, layer.mask != nil {
                switch replacement {
                case .transparent: u.maskMode = 1
                case .blur: u.maskMode = layer.blurred != nil ? 2 : 1
                case .color(let c):
                    u.maskMode = 3
                    u.maskColor = SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
                }
            }
            renderer.drawLayer(encoder, vertices: quad, source: layer.texture, uniforms: u,
                               lut: lut, mask: layer.mask, blurred: layer.blurred)
        }

        drawOverlays(scene: scene, time: time, canvas: canvas, renderer: renderer, encoder: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime((layers.map(\.keepAlive), targetRef)) {}
        return output
    }

    private func drawOverlays(scene: RenderScene, time: MediaTime, canvas: CGSize,
                              renderer: MetalRenderer, encoder: MTLRenderCommandEncoder) {
        for overlay in scene.texts {
            guard var state = OverlayAnimator.state(for: overlay, at: time) else { continue }
            if !scene.toggles.animationsEnabled { state = OverlayAnimationState() }   // paused: text at rest
            guard state.opacity > 0.001 else { continue }
            let key = "t-\(overlay.id)-\(overlay.text.hashValue)-\(overlay.style.hashValue)-\(state.visibleCharacters ?? -1)-\(Int(canvas.height))"
            let image: CGImage?
            if let cached = overlayCache[key] {
                image = cached
            } else {
                image = TextRasterizer.render(overlay, canvas: canvas, visibleCharacters: state.visibleCharacters)
                if overlayCache.count > 200 { overlayCache.removeAll() }
                overlayCache[key] = image
            }
            guard let image, let tex = renderer.texture(for: image) else { continue }
            let quad = LayerGeometry.overlayQuad(size: CGSize(width: image.width, height: image.height),
                                                 center: SIMD2(overlay.centerX, overlay.centerY + state.offsetY),
                                                 canvas: canvas, scale: overlay.scale * state.scale, rotation: overlay.rotation)
            renderer.drawOverlay(encoder, vertices: quad, texture: tex, opacity: Float(state.opacity))
        }

        if let (segment, active) = OverlayAnimator.caption(in: scene.captions, at: time) {
            let track = scene.captions
            let key = "c-\(segment.id)-\(active ?? -1)-\(track.preset.rawValue)-\(track.highlightColor.hashValue)-\(segment.text.hashValue)-\(Int(canvas.height))"
            let image: CGImage?
            if let cached = overlayCache[key] {
                image = cached
            } else {
                image = TextRasterizer.renderCaption(segment, activeWord: active, track: track, canvas: canvas)
                overlayCache[key] = image
            }
            if let image, let tex = renderer.texture(for: image) {
                // Subtle pop on the active word change for karaoke/bold presets.
                var scale = 1.0
                if let active, track.preset == .bold || track.preset == .karaoke {
                    let since = (time - segment.words[active].range.start).seconds
                    if since < 0.12 { scale = 1 + 0.04 * (1 - since / 0.12) }
                }
                let quad = LayerGeometry.overlayQuad(size: CGSize(width: image.width, height: image.height),
                                                     center: SIMD2(0.5, track.positionY), canvas: canvas, scale: scale)
                renderer.drawOverlay(encoder, vertices: quad, texture: tex, opacity: 1)
            }
        }
    }
}

/// Runs Vision person segmentation, reusing one request per clip so Vision can
/// keep masks temporally stable across frames.
final class SegmentationCache: @unchecked Sendable {
    private var requests: [UUID: VNGeneratePersonSegmentationRequest] = [:]
    private var stillMasks: [UUID: CVPixelBuffer] = [:]

    private func request(_ key: UUID, quality: RenderQuality) -> VNGeneratePersonSegmentationRequest {
        let level: VNGeneratePersonSegmentationRequest.QualityLevel = quality == .export ? .accurate : .balanced
        if let r = requests[key], r.qualityLevel == level { return r }
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = level
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        VisionSupport.configure(r)
        requests[key] = r
        return r
    }

    func mask(for buffer: CVPixelBuffer, quality: RenderQuality, key: UUID) -> CVPixelBuffer? {
        let r = request(key, quality: quality)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([r])
            return r.results?.first?.pixelBuffer
        } catch {
            return nil
        }
    }

    func mask(for image: CGImage, key: UUID) -> CVPixelBuffer? {
        if let m = stillMasks[key] { return m }
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .accurate
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        VisionSupport.configure(r)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([r])) != nil, let m = r.results?.first?.pixelBuffer else { return nil }
        stillMasks[key] = m
        return m
    }
}
