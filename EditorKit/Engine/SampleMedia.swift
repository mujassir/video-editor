@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Procedural media: synthesized music for the built-in library, and
/// synthetic clips used by tests and the demo project.
public enum SampleMedia {
    public typealias FrameDrawer = @Sendable (_ ctx: CGContext, _ size: CGSize, _ time: Double) -> Void

    /// Writes an H.264 video whose frames are drawn by `draw`.
    public static func makeVideo(url: URL, size: CGSize, duration: Double, fps: Int = 30,
                                 draw: FrameDrawer) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaImportError.unreadable }
        writer.startSession(atSourceTime: .zero)
        let frames = Int((duration * Double(fps)).rounded())
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw MediaImportError.unreadable }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw MediaImportError.unreadable }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                // Flip so drawing code uses a top-left origin.
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                draw(ctx, size, Double(i) / Double(fps))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaImportError.unreadable }
    }

    /// Writes mono 44.1 kHz audio generated sample by sample into an .m4a (AAC) file.
    public static func makeAudio(url: URL, duration: Double, sampleRate: Double = 44_100,
                                 generator: (_ samples: inout [Float], _ sampleRate: Double) -> Void) throws {
        try? FileManager.default.removeItem(at: url)
        var samples = [Float](repeating: 0, count: Int(duration * sampleRate))
        generator(&samples, sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_384
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            let dst = buffer.floatChannelData![0]
            for i in 0..<n { dst[i] = samples[offset + i] }
            try file.write(from: buffer)
            offset += n
        }
    }

    /// Combines a video file and an audio file into one movie.
    public static func mux(video: URL, audio: URL, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        let vDuration = try await v.load(.duration)
        if let src = try await v.loadTracks(withMediaType: .video).first,
           let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try t.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: src, at: .zero)
        }
        if let src = try await a.loadTracks(withMediaType: .audio).first,
           let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDuration = try await a.load(.duration)
            try t.insertTimeRange(CMTimeRange(start: .zero, duration: min(aDuration, vDuration)), of: src, at: .zero)
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cannotCreateSession
        }
        try await session.export(to: url, as: .mov)
    }

    // MARK: Music

    public struct Track: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let bpm: Double
        public let mood: String
        public let root: Double   // Hz
        public let minor: Bool
    }

    /// Built-in royalty-free tracks, synthesized on device.
    public static let library: [Track] = [
        Track(id: "sunrise", name: "Sunrise Drive", bpm: 120, mood: "Upbeat", root: 110, minor: false),
        Track(id: "night", name: "Night Run", bpm: 128, mood: "Energetic", root: 98, minor: true),
        Track(id: "chill", name: "Lo-Fi Chill", bpm: 84, mood: "Relaxed", root: 130.8, minor: false),
        Track(id: "epic", name: "Big Moment", bpm: 100, mood: "Cinematic", root: 87.3, minor: true),
    ]

    /// Beat times (seconds) of a synthesized track.
    public static func beatTimes(of track: Track, duration: Double) -> [Double] {
        let step = 60 / track.bpm
        return stride(from: 0.0, to: duration, by: step).map { $0 }
    }

    /// Renders a track: kick on every beat, hats on off-beats, bass and pad chords.
    public static func renderMusic(_ track: Track, duration: Double, to url: URL) throws {
        try makeAudio(url: url, duration: duration) { s, sr in
            let beat = 60 / track.bpm
            let n = s.count
            let third = track.minor ? 1.189 : 1.26
            let progression: [Double] = [1, 0.749, 0.841, 0.667] // I – IV(ish) – V – vi(ish) as frequency ratios
            var noiseSeed: UInt32 = 12345
            func noise() -> Float {
                noiseSeed = noiseSeed &* 1_664_525 &+ 1_013_904_223
                return Float(Int32(bitPattern: noiseSeed)) / Float(Int32.max)
            }
            for i in 0..<n {
                let t = Double(i) / sr
                let beatPos = t / beat
                let inBeat = (beatPos - floor(beatPos)) * beat
                let bar = Int(beatPos / 4) % progression.count
                let root = track.root * progression[bar]
                var v: Double = 0
                // Kick: pitch-swept sine with fast decay.
                if inBeat < 0.25 {
                    let f = 50 + 90 * exp(-inBeat * 30)
                    v += sin(2 * .pi * f * inBeat) * exp(-inBeat * 12) * 0.9
                }
                // Hi-hat on off-beats.
                let off = inBeat - beat / 2
                if off >= 0 && off < 0.05 {
                    v += Double(noise()) * exp(-off * 90) * 0.18
                }
                // Snare-ish clap on beats 2 and 4.
                let beatInBar = Int(beatPos) % 4
                if (beatInBar == 1 || beatInBar == 3) && inBeat < 0.12 {
                    v += Double(noise()) * exp(-inBeat * 30) * 0.3
                }
                // Bass on the root, eighth-note pulse.
                let eighth = (beatPos * 2 - floor(beatPos * 2)) * beat / 2
                v += sin(2 * .pi * root * t) * exp(-eighth * 6) * 0.25
                // Soft pad: root, third, fifth an octave up.
                let pad = sin(2 * .pi * root * 2 * t) + sin(2 * .pi * root * 2 * third * t) * 0.8 + sin(2 * .pi * root * 3 * t) * 0.6
                v += pad * 0.045
                s[i] = Float(tanh(v) * 0.85)
            }
            // Fade in/out to avoid clicks.
            let fade = Int(sr * 0.05)
            for i in 0..<min(fade, n) {
                let g = Float(i) / Float(fade)
                s[i] *= g
                s[n - 1 - i] *= g
            }
        }
    }

    // MARK: Synthetic clips

    /// A clip that is a single solid colour.
    public static func solid(_ c: RGBAColor) -> FrameDrawer {
        { ctx, size, _ in
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A colourful animated gradient with a moving ball – stands in for real footage.
    public static func animated(hue: Double) -> FrameDrawer {
        { ctx, size, t in
            let c1 = hsv(hue + t * 0.03, 0.75, 0.9), c2 = hsv(hue + 0.15 + t * 0.03, 0.85, 0.45)
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c1, c2] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let r = min(size.width, size.height) * 0.12
            let x = size.width * (0.5 + 0.35 * sin(t * 1.3))
            let y = size.height * (0.5 + 0.3 * cos(t * 0.9))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    /// Brightness ramps from black to white over `duration` – lets tests verify direction (reverse).
    public static func ramp(duration: Double) -> FrameDrawer {
        { ctx, size, t in
            let v = min(1, max(0, t / duration))
            ctx.setFillColor(CGColor(gray: v, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
        let h6 = (h - floor(h)) * 6
        let c = v * s, x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h6) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }

    /// Tone bursts separated by silence: `pattern` is [(isSound, seconds)].
    public static func renderTonePattern(_ pattern: [(Bool, Double)], to url: URL) throws {
        let total = pattern.reduce(0) { $0 + $1.1 }
        try makeAudio(url: url, duration: total) { s, sr in
            var t0 = 0.0
            for (sound, len) in pattern {
                if sound {
                    let a = Int(t0 * sr), b = min(s.count, Int((t0 + len) * sr))
                    for i in a..<b {
                        let t = Double(i) / sr
                        s[i] = Float(sin(2 * .pi * 220 * t) * 0.5 + sin(2 * .pi * 440 * t) * 0.2)
                    }
                }
                t0 += len
            }
        }
    }
}
