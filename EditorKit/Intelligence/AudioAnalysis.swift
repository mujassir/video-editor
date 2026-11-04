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
    static let hop = 128

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
            // Kick and bass (< ~200 Hz) define the beat in most music; weight them
            // well above broadband hats so the grid locks onto downbeats, not off-beats.
            var flux: Float = 0
            let lowBand = max(2, Int(200 / (sampleRate / Double(n))))
            for k in 1..<(n / 2) {
                let d = mags[k] - previous[k]
                if d > 0 { flux += k <= lowBand ? d * 12 : d }
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
        var env = onsetEnvelope(samples)
        let fps = sampleRate / Double(hop)
        guard env.count > Int(fps * 2) else { return nil }
        // Light smoothing widens onset peaks so fractional periods still hit them.
        if env.count > 2 {
            var smoothed = env
            for i in 1..<(env.count - 1) { smoothed[i] = 0.25 * env[i - 1] + 0.5 * env[i] + 0.25 * env[i + 1] }
            env = smoothed
        }
        let n = env.count

        // Comb search over fractional tempos: for each BPM, the best phase's mean
        // onset strength. Using the mean (not the sum) means a half-time comb that
        // skips every other kick scores lower than the true tempo.
        func comb(period: Double) -> (score: Float, phase: Double) {
            var best: Float = -1
            var bestPhase = 0.0
            let steps = max(1, Int(period.rounded()))
            for p in 0..<steps {
                var sum: Float = 0
                var count = 0
                var k = Double(p)
                while k < Double(n) - 0.5 {
                    sum += env[min(n - 1, Int(k.rounded()))]
                    count += 1
                    k += period
                }
                let mean = count > 0 ? sum / Float(count) : 0
                if mean > best { best = mean; bestPhase = Double(p) }
            }
            return (best, bestPhase)
        }
        var bestBPM = 120.0
        var bestScore = -Float.infinity
        var bestPhase = 0.0
        var bpm = 60.0
        while bpm <= 180 {
            let (score, phase) = comb(period: 60 * fps / bpm)
            // Mild prior towards ~120 BPM to break ties.
            let weight = Float(exp(-0.5 * pow(log2(bpm / 120) / 1.5, 2)))
            if score * weight > bestScore {
                bestScore = score * weight
                bestBPM = bpm
                bestPhase = phase
            }
            bpm += 0.25
        }
        // Fold into 80–160 BPM: snares on 2 & 4 make half time look strong, off-beat
        // hats make double time look strong; the musical tempo sits in between.
        var folded = bestBPM
        while folded < 80 { folded *= 2 }
        while folded >= 160 { folded /= 2 }
        if folded != bestBPM {
            bestBPM = folded
            bestPhase = comb(period: 60 * fps / folded).phase
        }
        let period = 60 * fps / bestBPM

        // Place beats on the grid, snapping each to the strongest nearby onset.
        var beats: [Double] = []
        var position = bestPhase
        let search = max(1, Int(period * 0.08))
        while Int(position.rounded()) < n {
            let centre = Int(position.rounded())
            var best = centre
            var bestValue = -Float.infinity
            for i in max(0, centre - search)...min(n - 1, centre + search) where env[i] > bestValue {
                bestValue = env[i]
                best = i
            }
            beats.append((Double(best) * Double(hop) + Double(fftSize) / 2) / sampleRate)
            position += period
        }
        return Result(bpm: bestBPM, beats: beats)
    }

    public static func detect(url: URL) async throws -> Result? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let samples = try Waveform.readMono(asset: asset, track: track, sampleRate: sampleRate)
        return detect(samples: samples)
    }
}
