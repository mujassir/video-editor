import Foundation
import CoreGraphics

// MARK: - Media

public enum MediaKind: String, Codable, Sendable {
    case video, photo, audio
}

/// A source file copied into the project's media folder.
public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MediaKind
    /// File name relative to the project's media directory.
    public var fileName: String
    public var naturalSize: CGSize
    public var duration: MediaTime
    public var hasAudio: Bool
    public var frameRate: Double
    public var displayName: String
    /// Reversed copy of a video, generated on demand for reversed clips.
    public var reversedFileName: String?
    /// Clockwise quarter turns needed to display the raw video frames upright
    /// (from the track's preferredTransform). `naturalSize` is the upright size.
    public var sourceQuarterTurns: Int = 0

    public init(id: UUID = UUID(), kind: MediaKind, fileName: String, naturalSize: CGSize,
                duration: MediaTime, hasAudio: Bool, frameRate: Double = 30, displayName: String = "") {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.naturalSize = naturalSize
        self.duration = duration
        self.hasAudio = hasAudio
        self.frameRate = frameRate
        self.displayName = displayName
    }
}

// MARK: - Canvas

public enum AspectRatio: String, Codable, CaseIterable, Sendable, Identifiable {
    case portrait9x16 = "9:16"
    case portrait3x4 = "3:4"
    case square1x1 = "1:1"
    case portrait4x5 = "4:5"
    case landscape16x9 = "16:9"

    public var id: String { rawValue }

    /// Width / height.
    public var value: Double {
        switch self {
        case .portrait9x16: return 9.0 / 16.0
        case .square1x1: return 1
        case .portrait3x4: return 3.0 / 4.0
        case .portrait4x5: return 4.0 / 5.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }

    /// Render size whose short edge equals `shortEdge` (rounded to even numbers for encoders).
    public func renderSize(shortEdge: Int) -> CGSize {
        func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
        if value >= 1 {
            return CGSize(width: even(Double(shortEdge) * value), height: shortEdge)
        } else {
            return CGSize(width: shortEdge, height: even(Double(shortEdge) / value))
        }
    }
}

public enum CanvasBackground: Codable, Hashable, Sendable {
    case blur
    case color(RGBAColor)
}

public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let yellow = RGBAColor(r: 1, g: 0.86, b: 0.1)
}

public enum ContentFit: String, Codable, Sendable {
    /// Whole frame visible, canvas background shows around it.
    case fit
    /// Frame covers the canvas, edges cropped.
    case fill
    /// Frame is scaled to exactly the canvas size (aspect ratio not kept).
    case stretch

    public var displayName: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }
}

/// Where media sits on the canvas when it doesn't match the canvas shape:
/// with `.fill` it chooses which part is kept, with `.fit` which edge it hugs.
public enum ContentAnchor: String, Codable, CaseIterable, Sendable, Identifiable {
    case center, top, bottom, left, right
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

// MARK: - Clip settings

/// Normalized crop rectangle in source pixel space (0...1).
public struct CropRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = CropRect()
    public var isFull: Bool { x == 0 && y == 0 && width == 1 && height == 1 }
}

public struct ClipTransform: Codable, Hashable, Sendable {
    public var crop: CropRect = .full
    /// Clockwise rotation in quarter turns (0...3).
    public var quarterTurns: Int = 0
    public var flipHorizontal = false
    public var flipVertical = false
    /// Additional user zoom (1 = none).
    public var scale: Double = 1
    /// Offset in canvas-normalized units (-1...1).
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var fit: ContentFit = .fit
    /// Optional so projects saved before anchors existed still load (nil = centre).
    public var anchor: ContentAnchor? = nil

    public init() {}
    public static let identity = ClipTransform()
}

/// Basic color adjustments. All values are neutral at 0.
public struct ColorAdjustments: Codable, Hashable, Sendable {
    public var exposure: Double = 0      // -1...1 stops (scaled ×2 in shader)
    public var contrast: Double = 0      // -1...1
    public var saturation: Double = 0    // -1...1
    public var warmth: Double = 0        // -1...1
    public var highlights: Double = 0    // -1...1
    public var shadows: Double = 0       // -1...1
    public var vignette: Double = 0      // 0...1
    public var sharpen: Double = 0       // 0...1

    public init() {}
    public static let neutral = ColorAdjustments()
    public var isNeutral: Bool { self == .neutral }
}

public struct FilterSetting: Codable, Hashable, Sendable {
    public var filterID: String
    public var intensity: Double
    public init(filterID: String, intensity: Double = 1) {
        self.filterID = filterID
        self.intensity = intensity
    }
}

public enum TransitionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case fade, dissolve, slideLeft, slideUp, zoom, wipe, blur, glitch
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fade: return "Fade"
        case .dissolve: return "Dissolve"
        case .slideLeft: return "Slide"
        case .slideUp: return "Push Up"
        case .zoom: return "Zoom"
        case .wipe: return "Wipe"
        case .blur: return "Blur"
        case .glitch: return "Glitch"
        }
    }
}

public struct Transition: Codable, Hashable, Sendable {
    public var kind: TransitionKind
    public var duration: MediaTime
    public init(kind: TransitionKind, duration: MediaTime = MediaTime(seconds: 0.5)) {
        self.kind = kind
        self.duration = duration
    }
}

/// Entrance / exit animation for a clip (exits play the entrance in reverse).
public enum ClipEntrance: String, Codable, CaseIterable, Sendable, Identifiable {
    case fade, zoomIn, zoomOut, slideLeft, slideRight, slideUp, slideDown, rotate, spin, pop, bounce, drop, blur, swing
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fade: return "Fade"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .slideLeft: return "Slide ←"
        case .slideRight: return "Slide →"
        case .slideUp: return "Slide ↑"
        case .slideDown: return "Slide ↓"
        case .rotate: return "Rotate"
        case .spin: return "Spin"
        case .pop: return "Pop"
        case .bounce: return "Bounce"
        case .drop: return "Drop"
        case .blur: return "Blur"
        case .swing: return "Swing"
        }
    }
    public var systemImage: String {
        switch self {
        case .fade: return "circle.lefthalf.filled"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .slideLeft: return "arrow.left"
        case .slideRight: return "arrow.right"
        case .slideUp: return "arrow.up"
        case .slideDown: return "arrow.down"
        case .rotate: return "rotate.right"
        case .spin: return "arrow.triangle.2.circlepath"
        case .pop: return "sparkle"
        case .bounce: return "arrow.up.and.down"
        case .drop: return "arrow.down.to.line"
        case .blur: return "drop"
        case .swing: return "metronome"
        }
    }
}

/// Looping emphasis animation across the whole clip.
public enum ClipCombo: String, Codable, CaseIterable, Sendable, Identifiable {
    case pulse, heartbeat, shake, wobble, swing, float, rock, spin
    public var id: String { rawValue }
    public var displayName: String { rawValue == "float" ? "Float" : rawValue.capitalized }
    public var systemImage: String {
        switch self {
        case .pulse: return "dot.radiowaves.left.and.right"
        case .heartbeat: return "heart"
        case .shake: return "waveform.path"
        case .wobble: return "rotate.left"
        case .swing: return "metronome"
        case .float: return "cloud"
        case .rock: return "arrow.left.and.right.circle"
        case .spin: return "arrow.clockwise"
        }
    }
}

public struct ClipAnimation: Codable, Hashable, Sendable {
    public var entrance: ClipEntrance?
    public var exit: ClipEntrance?
    public var combo: ClipCombo?
    public var inDuration: Double = 0.6
    public var outDuration: Double = 0.6
    public init() {}
    public var isEmpty: Bool { entrance == nil && exit == nil && combo == nil }
}

/// Animated camera move over a still image.
public enum PhotoMotion: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, zoomIn, zoomOut, panLeft, panRight, panUp, panDown, kenBurns
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .panLeft: return "Pan Left"
        case .panRight: return "Pan Right"
        case .panUp: return "Pan Up"
        case .panDown: return "Pan Down"
        case .kenBurns: return "Ken Burns"
        }
    }
    public var systemImage: String {
        switch self {
        case .none: return "nosign"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .panLeft: return "arrow.left"
        case .panRight: return "arrow.right"
        case .panUp: return "arrow.up"
        case .panDown: return "arrow.down"
        case .kenBurns: return "sparkles"
        }
    }
}

public enum BackgroundReplacement: Codable, Hashable, Sendable {
    /// Keep the person, blur everything else.
    case blur
    /// Keep the person on a solid color.
    case color(RGBAColor)
    /// Keep the person, show the project canvas background behind them.
    case transparent
}

/// A smoothed crop-centre path produced by auto-reframe (clip-local source time).
public struct ReframeKeyframe: Codable, Hashable, Sendable {
    public var time: MediaTime
    public var centerX: Double
    public var centerY: Double
    public init(time: MediaTime, centerX: Double, centerY: Double) {
        self.time = time
        self.centerX = centerX
        self.centerY = centerY
    }
}

// MARK: - Clips

/// A clip on the main (magnetic) video track.
public struct VideoClip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    public var kind: MediaKind
    /// Portion of the source media used, in source time.
    public var sourceRange: MediaTimeRange
    /// Playback rate (0.1...10).
    public var speed: Double = 1
    public var isReversed = false
    /// For freeze frames: still frame taken at this source time.
    public var freezeAt: MediaTime?
    public var volume: Double = 1
    public var isMuted = false
    public var transform = ClipTransform()
    public var filter: FilterSetting?
    public var adjustments = ColorAdjustments()
    public var backgroundRemoval: BackgroundReplacement?
    public var reframe: [ReframeKeyframe] = []
    /// Transition from this clip into the next one.
    public var transitionOut: Transition?
    /// Motion applied to photos and freeze frames (Ken Burns style). Optional so
    /// projects saved before this existed still load.
    public var photoMotion: PhotoMotion?
    /// In / Out / Combo animations (photos and videos). Optional so old projects load.
    public var animation: ClipAnimation?
    /// Set when this clip is an opening / closing slide.
    public var titleCard: TitleCard?

    public init(id: UUID = UUID(), mediaID: UUID, kind: MediaKind, sourceRange: MediaTimeRange) {
        self.id = id
        self.mediaID = mediaID
        self.kind = kind
        self.sourceRange = sourceRange
    }

    /// Duration this clip occupies on the timeline.
    public var timelineDuration: MediaTime {
        if kind == .photo || freezeAt != nil { return sourceRange.duration }
        return sourceRange.duration.divided(by: speed)
    }

    public var isStill: Bool { kind == .photo || freezeAt != nil }
    public var hasAudio: Bool { !isStill }

    /// Maps a time inside the clip (0..<timelineDuration) to source media time.
    public func sourceTime(atClipTime t: MediaTime) -> MediaTime {
        if let freezeAt { return freezeAt }
        if kind == .photo { return .zero }
        let offset = t.multiplied(by: speed)
        if isReversed {
            return sourceRange.end - offset
        }
        return sourceRange.start + offset
    }
}

/// Free-positioned audio on its own lane (music, voiceover, sound effects).
public struct AudioClip: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case music, voiceover, effect, extracted }

    public var id: UUID
    public var mediaID: UUID
    public var role: Role
    public var sourceRange: MediaTimeRange
    /// Position on the timeline.
    public var start: MediaTime
    public var volume: Double = 1
    public var fadeIn: MediaTime = .zero
    public var fadeOut: MediaTime = .zero
    public var lane: Int = 0
    /// Lower this clip while someone is speaking on the main track.
    public var autoDuck = false
    /// Beat times detected in the source (source time), if analysed.
    public var beats: [MediaTime] = []
    public var name: String = ""

    public init(id: UUID = UUID(), mediaID: UUID, role: Role, sourceRange: MediaTimeRange, start: MediaTime) {
        self.id = id
        self.mediaID = mediaID
        self.role = role
        self.sourceRange = sourceRange
        self.start = start
    }

    public var timelineRange: MediaTimeRange { MediaTimeRange(start: start, duration: sourceRange.duration) }

    /// Beat times mapped onto the timeline.
    public var timelineBeats: [MediaTime] {
        beats.filter { sourceRange.contains($0) }.map { start + ($0 - sourceRange.start) }
    }
}

public enum TextAnimation: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, fade, pop, slideUp, typewriter, bounce
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .slideUp: return "Rise"
        case .typewriter: return "Type"
        case .bounce: return "Bounce"
        }
    }
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var fontName: String = "HelveticaNeue-Bold"
    /// Font size as a fraction of canvas height.
    public var size: Double = 0.06
    public var color: RGBAColor = .white
    public var outlineColor: RGBAColor? = nil
    public var outlineWidth: Double = 0
    public var shadow = true
    public var backgroundColor: RGBAColor? = nil
    public init() {}
}

public struct TextOverlay: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var range: MediaTimeRange
    public var style = TextStyle()
    /// Centre position in canvas-normalized coordinates (0...1, origin top-left).
    public var centerX: Double = 0.5
    public var centerY: Double = 0.5
    public var rotation: Double = 0
    public var scale: Double = 1
    public var animationIn: TextAnimation = .pop
    public var animationOut: TextAnimation = .fade
    /// In / Out / Combo animation (same set as clips). When set it replaces the
    /// legacy `animationIn` / `animationOut`. Optional so old projects load.
    public var animation: ClipAnimation?
    /// Fixed placement that hugs a canvas edge/corner. nil = free position (centerX/Y).
    public var anchor: OverlayAnchor?

    public init(id: UUID = UUID(), text: String, range: MediaTimeRange) {
        self.id = id
        self.text = text
        self.range = range
    }
}

/// Fixed spots on the canvas for text and watermarks.
public enum OverlayAnchor: String, Codable, CaseIterable, Sendable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }
    /// -1 / 0 / +1 per axis (left/centre/right, top/centre/bottom).
    public var axes: SIMD2<Double> {
        switch self {
        case .topLeft: return SIMD2(-1, -1)
        case .top: return SIMD2(0, -1)
        case .topRight: return SIMD2(1, -1)
        case .left: return SIMD2(-1, 0)
        case .center: return SIMD2(0, 0)
        case .right: return SIMD2(1, 0)
        case .bottomLeft: return SIMD2(-1, 1)
        case .bottom: return SIMD2(0, 1)
        case .bottomRight: return SIMD2(1, 1)
        }
    }

    /// Centre (canvas-normalized) for an item of `size` px so it sits `margin` from the edges.
    public func center(for size: CGSize, canvas: CGSize, margin: Double = 0.04) -> SIMD2<Double> {
        let a = axes
        let hw = size.width / canvas.width / 2, hh = size.height / canvas.height / 2
        let mx = margin, my = margin * canvas.width / max(canvas.height, 1)   // same visual margin both axes
        let x = a.x < 0 ? mx + hw : (a.x > 0 ? 1 - mx - hw : 0.5)
        let y = a.y < 0 ? my + hh : (a.y > 0 ? 1 - my - hh : 0.5)
        return SIMD2(x, y)
    }
}

/// Logo or text stamped over the whole video.
public struct Watermark: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image }
    public var kind: Kind = .text
    public var text: String = "@yourname"
    /// Image file in the project's media folder (for `.image`).
    public var imageFileName: String?
    public var anchor: OverlayAnchor = .bottomRight
    public var opacity: Double = 0.7
    /// Width as a fraction of the canvas width (image) or text height factor (text).
    public var size: Double = 0.22
    public var color: RGBAColor = .white
    public init() {}
}

/// Opening / closing slide content. The slide itself is a photo clip whose image is
/// rendered from this description (square, content kept in the centre so it survives
/// any canvas ratio with Fill).
public struct TitleCard: Codable, Hashable, Sendable {
    public enum Placement: String, Codable, Sendable { case opening, closing }
    public var placement: Placement
    public var title: String
    public var subtitle: String = ""
    public var background: RGBAColor = RGBAColor(r: 0.08, g: 0.08, b: 0.1)
    public var accent: RGBAColor = RGBAColor(r: 1, g: 0.24, b: 0.38)
    public var textColor: RGBAColor = .white
    public var gradient = true
    public init(placement: Placement, title: String) {
        self.placement = placement
        self.title = title
    }
}

// MARK: - Captions

public struct CaptionWord: Codable, Hashable, Sendable {
    public var text: String
    public var range: MediaTimeRange
    public init(text: String, range: MediaTimeRange) {
        self.text = text
        self.range = range
    }
}

public struct CaptionSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var words: [CaptionWord]
    public init(id: UUID = UUID(), words: [CaptionWord]) {
        self.id = id
        self.words = words
    }
    public var text: String { words.map(\.text).joined(separator: " ") }
    public var range: MediaTimeRange {
        guard let first = words.first, let last = words.last else {
            return MediaTimeRange(start: .zero, duration: .zero)
        }
        return MediaTimeRange(start: first.range.start, end: last.range.end)
    }
}

public enum CaptionPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case classic, karaoke, bold, minimal, neon
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public struct CaptionTrack: Codable, Hashable, Sendable {
    public var segments: [CaptionSegment] = []
    public var preset: CaptionPreset = .karaoke
    public var highlightColor: RGBAColor = .yellow
    /// Vertical centre (0 top ... 1 bottom).
    public var positionY: Double = 0.78
    public var isVisible = true
    public init() {}
}

// MARK: - Project

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public static let currentVersion = 1

    public var version = Project.currentVersion
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var aspectRatio: AspectRatio = .portrait9x16
    public var background: CanvasBackground = .blur
    public var frameRate: Int = 30
    public var media: [MediaItem] = []
    public var clips: [VideoClip] = []
    public var audioClips: [AudioClip] = []
    public var textOverlays: [TextOverlay] = []
    public var captions = CaptionTrack()
    /// Fit applied to newly added media (set from the Canvas panel). Optional for old projects.
    public var watermark: Watermark?
    public var defaultFit: ContentFit?
    public var defaultAnchor: ContentAnchor?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    public func mediaItem(_ id: UUID) -> MediaItem? { media.first { $0.id == id } }
    public func clipIndex(_ id: UUID) -> Int? { clips.firstIndex { $0.id == id } }
}
