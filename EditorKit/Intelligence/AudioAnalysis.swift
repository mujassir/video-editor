@preconcurrency import AVFoundation
import Accelerate

/// Detects silent stretches (dead air between sentences) in speech audio.
public enum SilenceDetector {
    public struct Options: Sendable {
        /// Shortest pause worth removing.
        public var minimumSilence: Double = 0.6
        /// Audio kept on each side of a cut so words aren't clipped.
        public var padding: Double = 0.12
        /// Analysis window.
        public var window: Double = 0.02
        /// Where between the noise floor (0) and speech level (1) the threshold sits.
        public var thresholdPosition: Float = 0.3
        public init() {}
    }

    /// Per-window loudness in dBFS.
    public static func loudness(_ samples: [Float], sampleRate: Double, window: Double) -> [Float] {
        let n = max(1, Int(sampleRate * window))
        let count = samples.count / n
        guard count > 0 else { return [] }
        var levels = [Float](repeating: -100, count: count)
        samples.withUnsafeBufferPointer { ptr in
            for i in 0..<count {
                var rms: Float = 0
                vDSP_rmsqv(ptr.baseAddress! + i * n, 1, &rms, vDSP_Length(n))
                levels[i] = rms > 1e-5 ? 20 * log10(rms) : -100
            }
        }
        return levels
    }

    /// Silent ranges in seconds (relative to the start of `samples`).
    public static func silentRanges(_ samples: [Float], sampleRate: Double, options: Options = Options()) -> [ClosedRange<Double>] {
        let levels = loudness(samples, sampleRate: sampleRate, window: options.window)
        guard levels.count > 2 else { return [] }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let speech = sorted[Int(Double(sorted.count - 1) * 0.9)]
        // Nothing but noise or nothing but speech: no reliable pauses.
        guard speech - floor > 12 else { return [] }
        let threshold = floor + (speech - floor) * options.thresholdPosition

        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?
        for (i, level) in levels.enumerated() {
            if level < threshold {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                appendRun(start, i, &ranges, options, total: levels.count)
                runStart = nil
            }
        }
        if let start = runStart { appendRun(start, levels.count, &ranges, options, total: levels.count) }
        return ranges
    }

    private static func appendRun(_ start: Int, _ end: Int, _ ranges: inout [ClosedRange<Double>],
                                  _ o: Options, total: Int) {
        let s = Double(start) * o.window
        let e = Double(end) * o.window
        guard e - s >= o.minimumSilence else { return }
        // No padding at the very start / end of the audio: trim fully there.
        let ps = start == 0 ? s : s + o.padding
        let pe = end == total ? e : e - o.padding
        if pe > ps { ranges.append(ps...pe) }
    }

    /// Analyses the main track's mixed audio and returns timeline ranges to remove.
    public static func detect(project: Project, resolver: MediaResolver, options: Options = Options()) async throws -> [MediaTimeRange] {
        var speechOnly = project
        speechOnly.audioClips.removeAll { $0.role == .music || $0.role == .effect }
        let built = try await CompositionBuilder().build(project: speechOnly, resolver: resolver,
                                                         renderSize: CGSize(width: 64, height: 64))
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let sampleRate = 16_000.0
        let samples = try Waveform.readMixedMono(asset: built.composition, tracks: tracks,
                                                 audioMix: built.audioMix, sampleRate: sampleRate)
        return silentRanges(samples, sampleRate: sampleRate, options: options).map {
            MediaTimeRange(start: MediaTime(seconds: $0.lowerBound), end: MediaTime(seconds: $0.upperBound))
        }
    }
}

/// Tempo and beat tracking for music (spectral-flux onsets + autocorrelation).
public enum BeatDetector {
    public struct Result: Sendable {
        public var bpm: Double
        public var beats: [Double]
    }

    static let sampleRate = 11_025.0
    static let fftSize = 1024
    static let hop = 256

    /// Onset strength envelope (one value per hop).
    static func onsetEnvelope(_ samples: [Float]) -> [Float] {
        let n = fftSize
        guard samples.count > n,
              let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward,
                                                            transformType: .complexComplex, ofType: Float.self)
        else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let frames = (samples.count - n) / hop
        var previous = [Float](repeating: 0, count: n / 2)
        var envelope = [Float](repeating: 0, count: frames)
        let zeros = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var mags = [Float](repeating: 0, count: n / 2)
        for f in 0..<frames {
            let frame = vDSP.multiply(window, samples[(f * hop)..<(f * hop + n)])
            dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            for k in 0..<(n / 2) {
                mags[k] = log1p(10 * sqrt(re[k] * re[k] + im[k] * im[k]))
            }
            var flux: Float = 0
            for k in 1..<(n / 2) {
                let d = mags[k] - previous[k]
                if d > 0 { flux += d }
            }
            envelope[f] = flux
            swap(&previous, &mags)
        }
        // Remove slow trend (local mean) and half-wave rectify.
        let w = 16
        var result = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let a = max(0, i - w), b = min(frames, i + w + 1)
            var mean: Float = 0
            envelope.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + a, 1, &mean, vDSP_Length(b - a)) }
            result[i] = max(0, envelope[i] - mean)
        }
        return result
    }

    public static func detect(samples: [Float]) -> Result? {
        let env = onsetEnvelope(samples)
        let fps = sampleRate / Double(hop)
        guard env.count > Int(fps * 2) else { return nil }

        // Autocorrelation over 60–180 BPM, weighted towards ~120 BPM.
        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 60)
        var bestLag = minLag
        var bestScore = -Float.infinity
        var scores: [Int: Float] = [:]
        for lag in minLag...maxLag {
            var acc: Float = 0
            env.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &acc, vDSP_Length(env.count - lag))
            }
            acc /= Float(env.count - lag)
            scores[lag] = acc
            let bpm = 60 * fps / Double(lag)
            let weight = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            if acc * weight > bestScore {
                bestScore = acc * weight
                bestLag = lag
            }
        }
        // Parabolic interpolation for a fractional period.
        var period = Double(bestLag)
        if let a = scores[bestLag - 1], let b = scores[bestLag], let c = scores[bestLag + 1] {
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { period += Double(0.5 * (a - c) / denom) }
        }

        // Phase: offset whose comb best matches the onsets.
        var bestPhase = 0
        var bestPhaseScore = -Float.infinity
        for phase in 0..<bestLag {
            var sum: Float = 0
            var k = Double(phase)
            while Int(k) < env.count {
                sum += env[Int(k)]
                k += period
            }
            if sum > bestPhaseScore {
                bestPhaseScore = sum
                bestPhase = phase
            }
        }

        // Place beats on the grid, snapping each to the strongest nearby onset.
        var beats: [Double] = []
        var position = Double(bestPhase)
        let search = max(1, Int(period * 0.08))
        while Int(position) < env.count {
            let centre = Int(position.rounded())
            var best = centre
            var bestValue = -Float.infinity
            for i in max(0, centre - search)...min(env.count - 1, centre + search) where env[i] > bestValue {
                bestValue = env[i]
                best = i
            }
            // Onset frame index → time of the frame centre.
            beats.append((Double(best) * Double(hop) + Double(fftSize) / 2) / sampleRate)
            position += period
        }
        return Result(bpm: 60 * fps / period, beats: beats)
    }

    public static func detect(url: URL) async throws -> Result? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let samples = try Waveform.readMono(asset: asset, track: track, sampleRate: sampleRate)
        return detect(samples: samples)
    }
}
