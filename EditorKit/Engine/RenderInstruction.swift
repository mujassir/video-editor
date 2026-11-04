@preconcurrency import AVFoundation
import CoreGraphics

public enum RenderQuality: Sendable {
    /// Interactive preview: faster segmentation, cheaper background blur.
    case preview
    /// Final export: best-quality segmentation.
    case export
}

/// Everything the compositor needs to draw one main-track clip.
public struct ClipRenderInfo: @unchecked Sendable {
    public var clip: VideoClip
    public var media: MediaItem
    /// Track carrying this clip's frames (nil for stills).
    public var trackID: CMPersistentTrackID?
    /// Timeline range the clip occupies.
    public var timelineRange: MediaTimeRange
    public var overlapIn: MediaTime
    public var overlapOut: MediaTime
    /// Transition into this clip (owned by the previous clip).
    public var transitionIn: Transition?
    public var transitionOut: Transition?
}

/// Immutable description of a whole edit for rendering. Shared by every
/// instruction, so per-frame lookups (texts, captions) need no copying.
public final class RenderScene: @unchecked Sendable {
    public let renderSize: CGSize
    public let background: CanvasBackground
    public let quality: RenderQuality
    public let clips: [ClipRenderInfo]
    public let texts: [TextOverlay]
    public let captions: CaptionTrack
    /// Upright still images (photos and freeze frames) keyed by clip id.
    public let stills: [UUID: CGImage]
    /// Live switches the compositor reads every frame (shared with the editor).
    public let toggles: RenderToggles
    public let watermark: Watermark?
    public let watermarkImage: CGImage?

    public init(renderSize: CGSize, background: CanvasBackground, quality: RenderQuality,
                clips: [ClipRenderInfo], texts: [TextOverlay], captions: CaptionTrack, stills: [UUID: CGImage],
                toggles: RenderToggles = RenderToggles(),
                watermark: Watermark? = nil, watermarkImage: CGImage? = nil) {
        self.toggles = toggles
        self.watermark = watermark
        self.watermarkImage = watermarkImage
        self.renderSize = renderSize
        self.background = background
        self.quality = quality
        self.clips = clips
        self.texts = texts
        self.captions = captions
        self.stills = stills
    }
}

/// One stretch of the timeline with a fixed set of visible main-track clips.
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let scene: RenderScene
    /// Indices into `scene.clips` visible in this range, bottom to top.
    public let clipIndices: [Int]

    public init(timeRange: CMTimeRange, scene: RenderScene, clipIndices: [Int]) {
        self.timeRange = timeRange
        self.scene = scene
        self.clipIndices = clipIndices
        let ids = clipIndices.compactMap { scene.clips[$0].trackID }
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) }
        super.init()
    }
}

/// Preview switches that can change without rebuilding the composition.
public final class RenderToggles: @unchecked Sendable {
    private let lock = NSLock()
    private var _animations = true

    public init(animations: Bool = true) { _animations = animations }

    /// When false, clip In/Out/Combo animations, photo motion and text
    /// entrances/exits are not drawn (the editor's paused preview).
    public var animationsEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _animations }
        set { lock.lock(); _animations = newValue; lock.unlock() }
    }
}
