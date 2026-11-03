@preconcurrency import AVFoundation
@preconcurrency import Vision
import CoreGraphics
import CoreImage
import simd

/// Auto-reframe: follows faces / the most salient subject so a landscape clip
/// can fill a vertical canvas without losing the action.
public enum Reframer {
    public struct Sample: Sendable {
        public var time: MediaTime
        public var target: SIMD2<Double>?   // 0...1, origin top-left
    }

    /// Where the subject is in an upright frame (nil if nothing stands out).
    public static func subjectCenter(in image: CGImage) -> SIMD2<Double>? {
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([faces, saliency])
        func topLeft(_ r: CGRect) -> SIMD2<Double> { SIMD2(Double(r.midX), Double(1 - r.midY)) }
        if let found = faces.results, !found.isEmpty {
            // Favour the largest faces.
            let total = found.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
            let c = found.reduce(SIMD2<Double>.zero) { acc, f in
                acc + topLeft(f.boundingBox) * Double(f.boundingBox.width * f.boundingBox.height)
            }
            return c / max(total, 1e-6)
        }
        if let objects = saliency.results?.first?.salientObjects, let best = objects.max(by: {
            $0.confidence * Float($0.boundingBox.width * $0.boundingBox.height) < $1.confidence * Float($1.boundingBox.width * $1.boundingBox.height)
        }) {
            return topLeft(best.boundingBox)
        }
        return nil
    }

    /// Smooths raw targets into a steady camera path (dead zone + exponential smoothing).
    public static func smooth(_ samples: [Sample], deadZone: Double = 0.04, smoothing: Double = 0.35) -> [ReframeKeyframe] {
        var current = samples.first(where: { $0.target != nil })?.target ?? SIMD2(0.5, 0.5)
        var keys: [ReframeKeyframe] = []
        for sample in samples {
            if let target = sample.target {
                let delta = target - current
                if simd_length(delta) > deadZone {
                    current += delta * smoothing
                }
            }
            keys.append(ReframeKeyframe(time: sample.time, centerX: current.x, centerY: current.y))
        }
        return keys
    }

    /// Analyses a clip's source range and returns smoothed reframe keyframes (source time).
    public static func analyze(url: URL, range: MediaTimeRange, samplesPerSecond: Double = 4) async throws -> [ReframeKeyframe] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let count = max(2, Int(range.duration.seconds * samplesPerSecond))
        let times = (0..<count).map { i in
            range.start + MediaTime(seconds: range.duration.seconds * Double(i) / Double(count - 1)) - MediaTime(ticks: i == count - 1 ? 100 : 0)
        }
        var samples: [Sample] = []
        for await item in generator.images(for: times.map(\.cmTime)) {
            let t = MediaTime(item.requestedTime)
            if let image = try? item.image {
                samples.append(Sample(time: t, target: subjectCenter(in: image)))
            } else {
                samples.append(Sample(time: t, target: nil))
            }
        }
        samples.sort { $0.time < $1.time }
        return smooth(samples)
    }
}

/// One-tap "auto enhance": measures exposure, contrast, saturation and colour
/// cast across a few frames and maps them onto the clip's adjustment sliders.
public enum AutoEnhancer {
    public struct Stats: Sendable, Equatable {
        public var meanLuma: Double
        public var lumaStdDev: Double
        public var meanSaturation: Double
        public var redBlueBalance: Double
        public var shadowsP10: Double
    }

    public static func stats(of image: CGImage) -> Stats {
        let w = 64, h = 64
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lumas: [Double] = []
        lumas.reserveCapacity(w * h)
        var sat = 0.0, rb = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumas.append(l)
            let mx = max(r, g, b), mn = min(r, g, b)
            sat += mx > 0 ? (mx - mn) / mx : 0
            rb += r - b
        }
        let n = Double(lumas.count)
        let mean = lumas.reduce(0, +) / n
        let variance = lumas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let sorted = lumas.sorted()
        return Stats(meanLuma: mean, lumaStdDev: sqrt(variance), meanSaturation: sat / n,
                     redBlueBalance: rb / n, shadowsP10: sorted[Int(n * 0.1)])
    }

    /// Corrections that move the measured stats towards a pleasing target.
    public static func adjustments(for stats: Stats, keeping existing: ColorAdjustments = .neutral) -> ColorAdjustments {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        var a = existing
        a.exposure = clamp((0.48 - stats.meanLuma) * 1.4, -0.5, 0.6)
        a.contrast = clamp((0.22 - stats.lumaStdDev) * 2.0, -0.25, 0.35)
        a.saturation = clamp((0.38 - stats.meanSaturation) * 0.9, -0.2, 0.3)
        a.warmth = clamp(-stats.redBlueBalance * 1.2, -0.3, 0.3)
        a.shadows = clamp((0.08 - stats.shadowsP10) * 2.5, -0.1, 0.3)
        a.highlights = stats.meanLuma > 0.62 ? -0.25 : 0
        return a
    }

    /// Averages stats over a few frames of the clip.
    public static func analyze(url: URL, range: MediaTimeRange, isPhoto: Bool) async throws -> ColorAdjustments {
        var images: [CGImage] = []
        if isPhoto {
            if let image = MediaImporter.loadImage(url, maxPixelSize: 512) { images.append(image) }
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            let times = [0.2, 0.5, 0.8].map { range.start + MediaTime(seconds: range.duration.seconds * $0) }
            for await item in generator.images(for: times.map(\.cmTime)) {
                if let image = try? item.image { images.append(image) }
            }
        }
        guard !images.isEmpty else { return .neutral }
        let all = images.map(stats(of:))
        let n = Double(all.count)
        let avg = Stats(meanLuma: all.map(\.meanLuma).reduce(0, +) / n,
                        lumaStdDev: all.map(\.lumaStdDev).reduce(0, +) / n,
                        meanSaturation: all.map(\.meanSaturation).reduce(0, +) / n,
                        redBlueBalance: all.map(\.redBlueBalance).reduce(0, +) / n,
                        shadowsP10: all.map(\.shadowsP10).reduce(0, +) / n)
        return adjustments(for: avg)
    }
}

/// Person segmentation for a single still – used by tests and the cut-out preview.
public enum SubjectSegmenter {
    /// Fraction of the image covered by a person (0 when no person is found).
    public static func personCoverage(in image: CGImage) -> Double {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return 0 }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var covered = 0
        for y in 0..<h {
            for x in 0..<w where base[y * stride + x] > 127 { covered += 1 }
        }
        return Double(covered) / Double(w * h)
    }
}
