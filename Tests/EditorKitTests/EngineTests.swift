import Testing
import Foundation
import AVFoundation
import CoreGraphics
import simd
@testable import EditorKit

private func s(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

/// Creates a temporary project folder with generated media.
struct Fixture {
    let root: URL
    let store: ProjectStore
    var project: Project

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fx-\(UUID().uuidString)")
        store = ProjectStore(rootURL: root)
        project = try store.create(name: "Fixture")
    }

    var resolver: MediaResolver { MediaResolver(store: store, projectID: project.id) }

    /// Generates a clip into the media folder and appends it to the main track.
    @discardableResult
    mutating func addVideo(_ name: String, duration: Double, size: CGSize = CGSize(width: 320, height: 240),
                           draw: SampleMedia.FrameDrawer, audioPattern: [(Bool, Double)]? = nil) async throws -> MediaItem {
        let dir = store.mediaDirectory(for: project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let videoOnly = dir.appendingPathComponent("\(name)-v.mov")
        try await SampleMedia.makeVideo(url: videoOnly, size: size, duration: duration, draw: draw)
        var fileName = videoOnly.lastPathComponent
        if let audioPattern {
            let audio = dir.appendingPathComponent("\(name)-a.m4a")
            try SampleMedia.renderTonePattern(audioPattern, to: audio)
            let muxed = dir.appendingPathComponent("\(name).mov")
            try await SampleMedia.mux(video: videoOnly, audio: audio, to: muxed)
            fileName = muxed.lastPathComponent
        }
        let item = try await MediaImporter.probeVideo(dir.appendingPathComponent(fileName), fileName: fileName)
        project.appendClip(for: item)
        return item
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Renders one composed frame through the real compositor.
func renderFrame(_ built: BuiltComposition, at seconds: Double) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// Average RGB (0...1) of a region given in normalized coordinates (origin top-left).
func averageColor(_ image: CGImage, in rect: CGRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) -> SIMD3<Double> {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let x0 = Int(rect.minX * Double(w)), x1 = max(x0 + 1, Int(rect.maxX * Double(w)))
    let y0 = Int(rect.minY * Double(h)), y1 = max(y0 + 1, Int(rect.maxY * Double(h)))
    var sum = SIMD3<Double>.zero
    var n = 0.0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let i = (y * w + x) * 4
            sum += SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) / 255
            n += 1
        }
    }
    return sum / max(n, 1)
}

@Suite("Geometry")
struct GeometryTests {
    let media = MediaItem(kind: .video, fileName: "x", naturalSize: CGSize(width: 1920, height: 1080),
                          duration: s(1), hasAudio: false)

    @Test func unrotateQuarterTurn() {
        // Raw top-left becomes display top-right after a clockwise turn.
        #expect(LayerGeometry.unrotate(SIMD2(1, 0), turns: 1) == SIMD2(0, 0))
        #expect(LayerGeometry.unrotate(SIMD2(0.25, 0.5), turns: 0) == SIMD2(0.25, 0.5))
        #expect(LayerGeometry.unrotate(SIMD2(0.3, 0.7), turns: 4) == SIMD2(0.3, 0.7))
    }

    @Test func fitLandscapeInPortraitCanvas() {
        let canvas = CGSize(width: 1080, height: 1920)
        let quad = LayerGeometry.quad(media: media, transform: .identity, sourceTurns: 0, canvas: canvas)
        // Full width, letterboxed: height = 1080 * 1080/1920 = 607.5 px → NDC half-height 0.316.
        #expect(abs(quad[0].position.x + 1) < 0.001)
        #expect(abs(quad[1].position.x - 1) < 0.001)
        #expect(abs(quad[0].position.y - 0.3164) < 0.001)
        #expect(quad[0].uv == SIMD2(0, 0) && quad[3].uv == SIMD2(1, 1))
    }

    @Test func fillCoversCanvas() {
        var t = ClipTransform()
        t.fit = .fill
        let quad = LayerGeometry.quad(media: media, transform: t, sourceTurns: 0, canvas: CGSize(width: 1080, height: 1920))
        #expect(quad[0].position.y >= 1 - 0.001)
        #expect(quad[0].position.x < -1)
    }

    @Test func flipSwapsUVs() {
        var t = ClipTransform()
        t.flipHorizontal = true
        let quad = LayerGeometry.quad(media: media, transform: t, sourceTurns: 0, canvas: CGSize(width: 1920, height: 1080))
        #expect(quad[0].uv == SIMD2(1, 0))
    }

    @Test func reframeKeepsSubjectInsideCanvas() {
        let off = LayerGeometry.reframeOffset(center: SIMD2(0.9, 0.5), contentSize: CGSize(width: 3413, height: 1920),
                                              canvas: CGSize(width: 1080, height: 1920))
        // Moves content left, clamped so the right edge never enters the canvas.
        #expect(off.x < 0)
        #expect(off.x >= -((3413.0 - 1080) / 1080) / 2 - 0.0001)
        #expect(off.y == 0)
    }

    @Test func transitionAnimationsAreContinuous() {
        for kind in TransitionKind.allCases {
            let startIn = LayerGeometry.transitionAnimation(kind, progress: 1, incoming: true)
            #expect(startIn.opacity == 1, "\(kind) incoming should be fully visible at the end")
            let startOut = LayerGeometry.transitionAnimation(kind, progress: 0, incoming: false)
            #expect(startOut.opacity == 1 && startOut.brightness == 1, "\(kind) outgoing should start untouched")
        }
    }
}

@Suite("Filters & text")
struct FilterTextTests {
    @Test func monoLUTIsGray() throws {
        let mono = try #require(FilterLibrary.preset("mono"))
        let out = mono.apply(SIMD3(0.8, 0.2, 0.1))
        #expect(abs(out.x - out.y) < 0.0001 && abs(out.y - out.z) < 0.0001)
        let lut = FilterLibrary.lutData(for: mono, size: 9)
        #expect(lut.count == 729)
    }

    @Test func allPresetsStayInGamut() {
        for p in FilterLibrary.presets {
            for c in [SIMD3<Float>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(1, 0, 0), SIMD3(0.5, 0.5, 0.5)] {
                let o = p.apply(c)
                #expect(o.min() >= 0 && o.max() <= 1, "\(p.id)")
            }
        }
        #expect(FilterLibrary.presets.count == 20)
        #expect(Set(FilterLibrary.presets.map(\.id)).count == 20)
    }

    @Test func rasterizesTextAndCaptions() throws {
        let overlay = TextOverlay(text: "Hello World", range: MediaTimeRange(start: .zero, duration: s(2)))
        let image = try #require(TextRasterizer.render(overlay, canvas: CGSize(width: 1080, height: 1920)))
        #expect(image.width > 200 && image.height > 50)
        var track = CaptionTrack()
        let seg = CaptionSegment(words: [CaptionWord(text: "one", range: MediaTimeRange(start: .zero, duration: s(0.3))),
                                         CaptionWord(text: "two", range: MediaTimeRange(start: s(0.3), duration: s(0.3)))])
        for preset in CaptionPreset.allCases {
            track.preset = preset
            #expect(TextRasterizer.renderCaption(seg, activeWord: 1, track: track, canvas: CGSize(width: 1080, height: 1920)) != nil)
        }
    }

    @Test func overlayAnimationStates() {
        var overlay = TextOverlay(text: "Type me", range: MediaTimeRange(start: s(1), duration: s(3)))
        #expect(OverlayAnimator.state(for: overlay, at: s(0.5)) == nil)
        overlay.animationIn = .fade
        let early = OverlayAnimator.state(for: overlay, at: s(1.1))!
        #expect(early.opacity > 0 && early.opacity < 1)
        #expect(OverlayAnimator.state(for: overlay, at: s(2.5))!.opacity == 1)
        overlay.animationIn = .typewriter
        #expect(OverlayAnimator.state(for: overlay, at: s(1.2))!.visibleCharacters! < 7)
    }

    @Test func activeCaptionWord() {
        var track = CaptionTrack()
        track.segments = [CaptionSegment(words: [
            CaptionWord(text: "a", range: MediaTimeRange(start: s(1), duration: s(0.5))),
            CaptionWord(text: "b", range: MediaTimeRange(start: s(1.5), duration: s(0.5))),
        ])]
        #expect(OverlayAnimator.caption(in: track, at: s(0.5)) == nil)
        #expect(OverlayAnimator.caption(in: track, at: s(1.2))?.1 == 0)
        #expect(OverlayAnimator.caption(in: track, at: s(1.7))?.1 == 1)
    }
}

@Suite("Media engine", .serialized)
struct MediaEngineTests {
    @Test func probesGeneratedVideo() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        let item = try await fx.addVideo("red", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)),
                                         audioPattern: [(true, 2)])
        #expect(item.naturalSize == CGSize(width: 320, height: 240))
        #expect(abs(item.duration.seconds - 2) < 0.05)
        #expect(item.hasAudio)
        #expect(item.sourceQuarterTurns == 0)
    }

    @Test func compositionMatchesProjectDuration() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("a", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)))
        try await fx.addVideo("b", duration: 1.5, draw: SampleMedia.solid(RGBAColor(r: 0, g: 0, b: 1)))
        try fx.project.setTransition(Transition(kind: .dissolve, duration: s(0.5)), after: fx.project.clips[0].id)
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 180, height: 320))
        #expect(abs(built.composition.duration.seconds - 3.0) < 0.02)
        let instructions = built.videoComposition.instructions
        // Instructions tile the timeline without gaps.
        var cursor = CMTime.zero
        for i in instructions {
            #expect(i.timeRange.start == cursor)
            cursor = i.timeRange.end
        }
        #expect(abs(cursor.seconds - 3.0) < 0.001)
    }

    @Test func rendersClipsFiltersAndBackground() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("red", duration: 1, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)))
        fx.project.background = .color(RGBAColor(r: 0, g: 1, b: 0))
        let size = CGSize(width: 180, height: 320)

        var built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver, renderSize: size)
        var frame = try await renderFrame(built, at: 0.5)
        #expect(frame.width == 180 && frame.height == 320)
        let centre = averageColor(frame)
        #expect(centre.x > 0.85 && centre.y < 0.15, "centre should be the red clip, got \(centre)")
        let top = averageColor(frame, in: CGRect(x: 0.4, y: 0.02, width: 0.2, height: 0.05))
        #expect(top.y > 0.85 && top.x < 0.15, "letterbox should show the green canvas, got \(top)")

        // Mono filter → grey.
        try fx.project.updateClip(fx.project.clips[0].id) { $0.filter = FilterSetting(filterID: "mono") }
        built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver, renderSize: size)
        frame = try await renderFrame(built, at: 0.5)
        let mono = averageColor(frame)
        #expect(abs(mono.x - mono.y) < 0.05 && abs(mono.y - mono.z) < 0.05, "mono should be grey, got \(mono)")

        // Exposure down → darker.
        try fx.project.updateClip(fx.project.clips[0].id) { $0.filter = nil; $0.adjustments.exposure = -1 }
        built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver, renderSize: size)
        frame = try await renderFrame(built, at: 0.5)
        #expect(averageColor(frame).x < 0.6)
    }

    @Test func blurredBackgroundFillsLetterbox() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("red", duration: 1, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)))
        fx.project.background = .blur
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 180, height: 320))
        let frame = try await renderFrame(built, at: 0.5)
        let top = averageColor(frame, in: CGRect(x: 0.4, y: 0.02, width: 0.2, height: 0.05))
        #expect(top.x > 0.4 && top.y < 0.2, "blurred red should fill the letterbox, got \(top)")
    }

    @Test func dissolveBlendsClips() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("red", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)))
        try await fx.addVideo("blue", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 0, g: 0, b: 1)))
        fx.project.background = .color(.black)
        try fx.project.setTransition(Transition(kind: .dissolve, duration: s(1)), after: fx.project.clips[0].id)
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 160, height: 120))
        let before = averageColor(try await renderFrame(built, at: 0.5))
        let mid = averageColor(try await renderFrame(built, at: 1.5))
        let after = averageColor(try await renderFrame(built, at: 2.6))
        #expect(before.x > 0.9 && before.z < 0.1)
        #expect(mid.x > 0.25 && mid.z > 0.25, "mid-dissolve should mix red and blue, got \(mid)")
        #expect(after.z > 0.9 && after.x < 0.1)
    }

    @Test func rendersTextOverlay() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("black", duration: 2, draw: SampleMedia.solid(.black))
        fx.project.background = .color(.black)
        let id = fx.project.addText("HELLO", at: .zero, duration: s(2))
        fx.project.updateText(id) { $0.style.size = 0.2; $0.animationIn = .none; $0.animationOut = .none }
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 320, height: 320))
        let frame = try await renderFrame(built, at: 1)
        let c = averageColor(frame, in: CGRect(x: 0.2, y: 0.42, width: 0.6, height: 0.16))
        #expect(c.x > 0.15, "white text should brighten the centre, got \(c)")
    }

    @Test func speedAndPhotoClips() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("a", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)), audioPattern: [(true, 2)])
        try fx.project.setSpeed(2, clipID: fx.project.clips[0].id)
        // A generated photo.
        let photoURL = fx.store.mediaDirectory(for: fx.project.id).appendingPathComponent("photo.png")
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let dest = CGImageDestinationCreateWithURL(photoURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let photo = try MediaImporter.probeImage(photoURL, fileName: "photo.png")
        fx.project.appendClip(for: photo, photoDuration: s(1))
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 64, height: 64))
        #expect(abs(built.composition.duration.seconds - 2) < 0.03)
        let photoFrame = averageColor(try await renderFrame(built, at: 1.5))
        #expect(photoFrame.z > 0.9 && photoFrame.x < 0.1, "photo should render blue, got \(photoFrame)")
    }

    @Test func reversedVideoPlaysBackwards() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        var item = try await fx.addVideo("ramp", duration: 2, draw: SampleMedia.ramp(duration: 2))
        let dir = fx.store.mediaDirectory(for: fx.project.id)
        let reversed = dir.appendingPathComponent("ramp-rev.mov")
        try await UtilityMedia.makeReversedVideo(source: dir.appendingPathComponent(item.fileName), destination: reversed)
        item.reversedFileName = reversed.lastPathComponent
        fx.project.media[0] = item
        try fx.project.setReversed(true, clipID: fx.project.clips[0].id)
        fx.project.background = .color(.black)
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 160, height: 120))
        let start = averageColor(try await renderFrame(built, at: 0.1)).x
        let end = averageColor(try await renderFrame(built, at: 1.85)).x
        #expect(start > end + 0.5, "reversed ramp should go from bright to dark: \(start) → \(end)")
    }

    @Test func exportsMP4() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("a", duration: 1.5, draw: SampleMedia.animated(hue: 0.1), audioPattern: [(true, 1.5)])
        try await fx.addVideo("b", duration: 1.5, draw: SampleMedia.animated(hue: 0.6), audioPattern: [(true, 1.5)])
        try fx.project.setTransition(Transition(kind: .slideLeft, duration: s(0.5)), after: fx.project.clips[0].id)
        fx.project.addText("Export", at: .zero, duration: s(2))
        let out = fx.root.appendingPathComponent("out.mp4")
        let started = Date()
        try await Exporter.export(project: fx.project, resolver: fx.resolver,
                                  settings: ExportSettings(resolution: .p720, frameRate: 30, codec: .hevc),
                                  to: out) { _ in }
        let elapsed = Date().timeIntervalSince(started)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.5) < 0.1)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 720, height: 1280))
        #expect(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty)
        print("PERF export 2.5s 720p: \(String(format: "%.2f", elapsed))s")
    }

    @Test func waveformPeaks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wave-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try SampleMedia.renderTonePattern([(true, 0.5), (false, 0.5)], to: url)
        let peaks = try await Waveform.peaks(url: url, buckets: 10)
        #expect(peaks.count == 10)
        #expect(peaks[1] > 0.5 && peaks[8] < 0.1)
    }

    @Test func synthesizedMusicIsValid() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try SampleMedia.renderMusic(SampleMedia.library[0], duration: 4, to: url)
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(d - 4) < 0.1)
    }
}

@Suite("Photo animation")
struct PhotoMotionTests {
    private func s(_ v: Double) -> MediaTime { MediaTime(seconds: v) }

    @Test func movesStayWithinSafeZoom() {
        for motion in PhotoMotion.allCases {
            for p in stride(from: 0.0, through: 1.0, by: 0.1) {
                let a = LayerGeometry.photoMotion(motion, progress: p)
                #expect(a.scale >= 1 && a.scale <= 1.3, "\(motion) scale \(a.scale)")
                // Offset never exceeds what the zoom can hide (half the overflow).
                let allowance = (a.scale - 1) / 2 + 0.0001
                #expect(abs(a.offset.x) <= allowance && abs(a.offset.y) <= allowance, "\(motion) offset \(a.offset)")
            }
        }
        #expect(LayerGeometry.photoMotion(.zoomIn, progress: 0).scale == 1)
        #expect(abs(LayerGeometry.photoMotion(.zoomIn, progress: 1).scale - 1.25) < 1e-9)
        #expect(LayerGeometry.photoMotion(.panLeft, progress: 0).offset.x > 0)
        #expect(LayerGeometry.photoMotion(.panLeft, progress: 1).offset.x < 0)
        #expect(LayerGeometry.photoMotion(.none, progress: 0.5) == LayerAnimation())
    }

    @Test func setMotionOnPhotosOnly() throws {
        var p = Project(name: "P")
        let video = MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(2), hasAudio: false)
        let photo = MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false)
        p.appendClip(for: photo)
        p.appendClip(for: video)
        p.appendClip(for: MediaItem(kind: .photo, fileName: "b.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false))
        try p.setPhotoMotion(.zoomIn, clipID: p.clips[1].id)
        #expect(p.clips[1].photoMotion == nil, "videos are not animated")
        try p.setPhotoMotion(.kenBurns, clipID: p.clips[0].id, allPhotos: true)
        #expect(p.clips[0].photoMotion == .kenBurns && p.clips[2].photoMotion == .kenBurns)
        try p.setPhotoMotion(PhotoMotion.none, clipID: p.clips[2].id)
        #expect(p.clips[2].photoMotion == nil)
    }

    @Test func oldProjectsWithoutMotionStillLoad() throws {
        var clip = VideoClip(mediaID: UUID(), kind: .photo, sourceRange: MediaTimeRange(start: .zero, duration: s(3)))
        clip.photoMotion = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as! [String: Any]
        json.removeValue(forKey: "photoMotion")
        let decoded = try JSONDecoder().decode(VideoClip.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.photoMotion == nil)
    }

    @Test func zoomInRendersLargerAtTheEnd() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        // Black photo with a white centre square spanning 0.375–0.625.
        let url = fx.store.mediaDirectory(for: fx.project.id).appendingPathComponent("square.png")
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 48, y: 48, width: 32, height: 32))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let photo = try MediaImporter.probeImage(url, fileName: "square.png")
        fx.project.appendClip(for: photo, photoDuration: s(3))
        fx.project.aspectRatio = .square1x1
        fx.project.background = .color(.black)
        try fx.project.setPhotoMotion(.zoomIn, clipID: fx.project.clips[0].id)
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 128, height: 128))
        // A strip just outside the square at the start; covered once zoomed in.
        let strip = CGRect(x: 0.35, y: 0.45, width: 0.015, height: 0.1)
        let start = averageColor(try await renderFrame(built, at: 0.05), in: strip).x
        let end = averageColor(try await renderFrame(built, at: 2.95), in: strip).x
        #expect(start < 0.2 && end > 0.8, "zoom-in should grow the square: \(start) → \(end)")
    }
}

@Suite("Canvas fit")
struct CanvasFitTests {
    let landscape = MediaItem(kind: .photo, fileName: "x", naturalSize: CGSize(width: 1600, height: 900),
                              duration: .zero, hasAudio: false)
    let canvas = CGSize(width: 1080, height: 1920)

    private func quad(_ fit: ContentFit, _ anchor: ContentAnchor? = nil) -> [QuadVertex] {
        var t = ClipTransform()
        t.fit = fit
        t.anchor = anchor
        return LayerGeometry.quad(media: landscape, transform: t, sourceTurns: 0, canvas: canvas)
    }

    @Test func stretchCoversCanvasExactly() {
        let q = quad(.stretch)
        #expect(abs(q[0].position.x + 1) < 1e-5 && abs(q[0].position.y - 1) < 1e-5)
        #expect(abs(q[3].position.x - 1) < 1e-5 && abs(q[3].position.y + 1) < 1e-5)
        #expect(q[0].uv == SIMD2(0, 0) && q[3].uv == SIMD2(1, 1), "stretch shows the whole image")
    }

    @Test func fillAnchorsChooseTheKeptSide() {
        // Landscape in a portrait canvas overflows horizontally.
        let left = quad(.fill, .left), right = quad(.fill, .right), centre = quad(.fill)
        #expect(abs(left[0].position.x + 1) < 1e-5, "left edge of the photo on the canvas' left edge")
        #expect(abs(right[1].position.x - 1) < 1e-5, "right edge of the photo on the canvas' right edge")
        #expect(abs((centre[0].position.x + centre[1].position.x)) < 1e-5, "centred by default")
    }

    @Test func fitAnchorsHugAnEdge() {
        // Landscape fitted in a portrait canvas leaves space above and below.
        let top = quad(.fit, .top), bottom = quad(.fit, .bottom)
        #expect(abs(top[0].position.y - 1) < 1e-5, "photo touches the top")
        #expect(abs(bottom[2].position.y + 1) < 1e-5, "photo touches the bottom")
    }

    @Test func canvasFitAppliesToAllAndNewClips() {
        var p = Project(name: "P")
        p.appendClip(for: landscape)
        p.setContentFit(.fill, anchor: .top)
        #expect(p.clips[0].transform.fit == .fill && p.clips[0].transform.anchor == .top)
        var other = landscape
        other.id = UUID()
        p.appendClip(for: other)
        #expect(p.clips[1].transform.fit == .fill && p.clips[1].transform.anchor == .top)
    }
}

@Suite("Clip animations")
struct ClipAnimationTests {
    private func s(_ v: Double) -> MediaTime { MediaTime(seconds: v) }

    @Test func everyEntranceEndsAtRest() {
        for k in ClipEntrance.allCases {
            let a = LayerGeometry.entrance(k, progress: 1)
            #expect(abs(a.scale - 1) < 0.02 && abs(a.rotation) < 0.01 && abs(a.offset.x) < 0.01 && abs(a.offset.y) < 0.01,
                    "\(k) should end at rest, got \(a)")
            #expect(a.opacity > 0.99 && a.blurRadius < 0.01, "\(k) fully visible at the end")
        }
        // Starting poses actually differ from rest.
        #expect(LayerGeometry.entrance(.fade, progress: 0).opacity == 0)
        #expect(LayerGeometry.entrance(.slideLeft, progress: 0).offset.x == 1)
        #expect(LayerGeometry.entrance(.spin, progress: 0).rotation < -6)
    }

    @Test func combosStaySubtle() {
        for k in ClipCombo.allCases where k != .spin {
            for t in stride(from: 0.0, to: 4, by: 0.05) {
                let a = LayerGeometry.combo(k, seconds: t)
                #expect(a.scale >= 0.99 && a.scale <= 1.1, "\(k) scale \(a.scale)")
                #expect(abs(a.rotation) <= 0.11 && abs(a.offset.x) <= 0.02 && abs(a.offset.y) <= 0.03, "\(k) at \(t)")
            }
        }
    }

    @Test func inAndOutDontOverlapOnShortClips() {
        var anim = ClipAnimation()
        anim.entrance = .fade
        anim.exit = .fade
        anim.inDuration = 2
        anim.outDuration = 2
        // 1 s clip: In covers 0–0.5 s, Out 0.5–1 s.
        #expect(abs(LayerGeometry.clipAnimation(anim, local: 0.25, duration: 1).opacity - 0.5) < 0.01)
        #expect(abs(LayerGeometry.clipAnimation(anim, local: 0.75, duration: 1).opacity - 0.5) < 0.01)
        // Middle of a long clip is untouched.
        #expect(LayerGeometry.clipAnimation(anim, local: 5, duration: 10) == LayerAnimation())
    }

    @Test func rotationTurnsTheQuad() {
        let media = MediaItem(kind: .photo, fileName: "x", naturalSize: CGSize(width: 100, height: 100), duration: .zero, hasAudio: false)
        var a = LayerAnimation()
        a.rotation = .pi / 2
        let q = LayerGeometry.quad(media: media, transform: .identity, sourceTurns: 0, canvas: CGSize(width: 100, height: 100), animation: a)
        // A quarter turn clockwise moves the top-left corner to the top-right.
        #expect(abs(q[0].position.x - 1) < 1e-4 && abs(q[0].position.y - 1) < 1e-4)
    }

    @Test func oldClipsWithoutAnimationLoad() throws {
        let clip = VideoClip(mediaID: UUID(), kind: .video, sourceRange: MediaTimeRange(start: .zero, duration: s(2)))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as! [String: Any]
        json.removeValue(forKey: "animation")
        let decoded = try JSONDecoder().decode(VideoClip.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.animation == nil)
    }

    @Test func slideInRendersFromOffscreen() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("red", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)))
        fx.project.background = .color(RGBAColor(r: 0, g: 0, b: 1))
        try fx.project.updateClip(fx.project.clips[0].id) { c in
            var a = ClipAnimation()
            a.entrance = .slideLeft
            a.inDuration = 1
            c.animation = a
            c.transform.fit = .fill
        }
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 160, height: 120))
        let early = averageColor(try await renderFrame(built, at: 0.02), in: CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2))
        let settled = averageColor(try await renderFrame(built, at: 1.5), in: CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2))
        #expect(early.z > 0.8, "clip still off to the right, canvas shows: \(early)")
        #expect(settled.x > 0.8 && settled.z < 0.2, "clip slid in: \(settled)")
    }

    @Test func pausedPreviewShowsClipsAtRest() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("red", duration: 2, draw: SampleMedia.solid(RGBAColor(r: 1, g: 0, b: 0)))
        fx.project.background = .color(RGBAColor(r: 0, g: 0, b: 1))
        try fx.project.updateClip(fx.project.clips[0].id) { c in
            var a = ClipAnimation()
            a.entrance = .slideLeft
            a.inDuration = 1
            c.animation = a
            c.transform.fit = .fill
        }
        let toggles = RenderToggles(animations: false)
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 160, height: 120), toggles: toggles)
        let region = CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2)
        let paused = averageColor(try await renderFrame(built, at: 0.02), in: region)
        #expect(paused.x > 0.8 && paused.z < 0.2, "paused: clip shown at rest, got \(paused)")
        toggles.animationsEnabled = true
        let playing = averageColor(try await renderFrame(built, at: 0.03), in: region)
        #expect(playing.z > 0.8, "playing: slide-in animation drawn, got \(playing)")
    }
}

@Suite("Text, watermark, title cards")
struct OverlayFeatureTests {
    private func s(_ v: Double) -> MediaTime { MediaTime(seconds: v) }

    @Test func anchorsHugEdges() {
        let canvas = CGSize(width: 1000, height: 1000)
        let size = CGSize(width: 200, height: 100)
        let tl = OverlayAnchor.topLeft.center(for: size, canvas: canvas, margin: 0.05)
        #expect(abs(tl.x - 0.15) < 1e-9 && abs(tl.y - 0.1) < 1e-9)
        let br = OverlayAnchor.bottomRight.center(for: size, canvas: canvas, margin: 0.05)
        #expect(abs(br.x - 0.85) < 1e-9 && abs(br.y - 0.9) < 1e-9)
        #expect(OverlayAnchor.center.center(for: size, canvas: canvas) == SIMD2(0.5, 0.5))
    }

    @Test func textEditingHelpers() {
        var p = Project(name: "P")
        let id = p.addText("Hi", at: s(1))
        #expect(p.textOverlays[0].animation?.entrance == .pop, "new text uses the shared animation set")
        p.setTextDuration(id, s(100))
        #expect(p.textOverlays[0].range.duration == s(30))
        p.setTextAnchor(id, .bottom)
        #expect(p.textOverlays[0].anchor == .bottom)
        let copy = p.duplicateText(id)
        #expect(p.textOverlays.count == 2 && p.textOverlays[1].id == copy && p.textOverlays[1].range.start == s(31))
    }

    @Test func titleCardsGoFirstAndLast() throws {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(4), hasAudio: false))
        let img = MediaItem(kind: .photo, fileName: "t.png", naturalSize: CGSize(width: 2160, height: 2160), duration: .zero, hasAudio: false)
        p.upsertTitleCard(TitleCard(placement: .opening, title: "Hello"), image: img, duration: s(3))
        p.upsertTitleCard(TitleCard(placement: .closing, title: "Bye"), image: img, duration: s(2))
        #expect(p.clips.first?.titleCard?.placement == .opening && p.clips.last?.titleCard?.placement == .closing)
        #expect(p.layout.duration == s(9))
        // Updating replaces, never duplicates.
        p.upsertTitleCard(TitleCard(placement: .opening, title: "Hello again"), image: img, duration: s(4))
        #expect(p.clips.count == 3 && p.clips[0].titleCard?.title == "Hello again" && p.layout.duration == s(10))
        p.setContentFit(.stretch, anchor: .center)
        #expect(p.clips[0].transform.fit == .fill, "slides always fill")
        p.removeTitleCard(.closing)
        #expect(p.clips.count == 2)
    }

    @Test func titleCardPresets() {
        var card = TitleCard(placement: .opening, title: "Hi")
        #expect(card.preset?.id == "midnight", "default colours are the Midnight preset")
        let paper = TitleCard.presets.first { $0.id == "paper" }!
        card.apply(paper)
        #expect(card.preset?.id == "paper" && card.gradient == false)
        #expect(Set(TitleCard.presets.map(\.id)).count == TitleCard.presets.count)
    }

    @Test func titleCardRendersSquarePNG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var card = TitleCard(placement: .opening, title: "Road Trip")
        card.subtitle = "Summer 2026"
        let item = try TitleCardRenderer.write(card, to: dir)
        #expect(item.kind == .photo && item.naturalSize == CGSize(width: 2160, height: 2160))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(item.fileName).path))
    }

    @Test func watermarkIsDrawnOverTheVideo() async throws {
        var fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.addVideo("black", duration: 1, draw: SampleMedia.solid(.black))
        fx.project.background = .color(.black)
        var mark = Watermark()
        mark.text = "WATERMARK"
        mark.anchor = .center
        mark.size = 0.5
        mark.opacity = 1
        fx.project.watermark = mark
        let built = try await CompositionBuilder().build(project: fx.project, resolver: fx.resolver,
                                                         renderSize: CGSize(width: 320, height: 320))
        let c = averageColor(try await renderFrame(built, at: 0.5), in: CGRect(x: 0.2, y: 0.45, width: 0.6, height: 0.1))
        #expect(c.x > 0.1, "white watermark text should brighten the centre, got \(c)")
    }
}

@Suite("Export estimate")
struct ExportEstimateTests {
    @Test func sizeGrowsWithQualityAndLength() {
        let minute = MediaTime(seconds: 60)
        let hd = ExportSettings(resolution: .p1080, frameRate: 30, codec: .h264).estimatedBytes(duration: minute)
        // 16 Mbps video + 256 kbps audio for 60 s ≈ 122 MB.
        #expect(abs(Double(hd) - 121_920_000) < 1_000_000)
        #expect(ExportSettings(resolution: .p1080, frameRate: 30, codec: .hevc).estimatedBytes(duration: minute) < hd)
        #expect(ExportSettings(resolution: .p2160, frameRate: 30, codec: .h264).estimatedBytes(duration: minute) > hd)
        #expect(ExportSettings(resolution: .p1080, frameRate: 60, codec: .h264).estimatedBytes(duration: minute) > hd)
        #expect(ExportSettings().estimatedBytes(duration: .zero) == 0)
    }
}
