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


// MARK: - Noise reduction

/// Removes steady background noise (hiss, hum, wind, room tone) from speech.
///
/// Spectral gating: the quietest moments of the clip give a noise fingerprint per frequency;
/// every frame is then turned down in the frequencies where it is not clearly louder than that
/// fingerprint. Runs on device with Accelerate; the result keeps the original's channels and timing.
public enum NoiseReducer {
    static let frameSize = 2048
    static let hop = 512

    struct Settings {
        /// How far above the noise fingerprint a frequency must be to pass untouched.
        var oversubtraction: Float
        /// Lowest gain, so noise is reduced rather than gated to dead silence.
        var floor: Float
    }

    static func settings(_ level: NoiseReduction) -> Settings {
        switch level {
        case .low: Settings(oversubtraction: 1.5, floor: 0.30)
        case .medium: Settings(oversubtraction: 2.2, floor: 0.15)
        case .high: Settings(oversubtraction: 3.0, floor: 0.06)
        }
    }

    /// Cleans the audio of `source` and writes it (lossless, same channels, same start) to `destination`.
    public static func process(source: URL, destination: URL, level: NoiseReduction,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaImportError.unsupported }
        let descriptions = try await track.load(.formatDescriptions)
        let sourceChannels = descriptions.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let channelCount = Int(min(max(sourceChannels, 1), 2))
        let sampleRate = 48_000.0
        let (channels, offset) = try read(asset: asset, track: track, channels: channelCount, sampleRate: sampleRate)
        let cleaned = reduce(channels: channels, level: level, progress: progress)
        // Silence for any gap before the track's first sample keeps the cleaned copy in sync.
        let lead = Int((offset * sampleRate).rounded())
        try write(cleaned, leadingSilence: max(0, lead), sampleRate: sampleRate, to: destination)
    }

    /// Frames that give the noise fingerprint (DNS-6, IMPLEMENTATION §9.4): the quietest 10% of
    /// the frames that sit at or near the clip's real noise floor. `energies` are per frame of the
    /// padded signal; `length` is the unpadded sample count.
    ///
    /// Frames quieter than the floor (the padding, digital silence, a fade-in, the mic starting up,
    /// a muted moment) are left out. Before this, they could fill the quietest 10% on their own,
    /// so the fingerprint was near zero and nothing was removed.
    static func noiseFrames(energies: [Float], length: Int) -> [Int] {
        let first = frameSize / hop, last = min(energies.count - 1, length / hop)
        let inside = first <= last ? Array(first...last) : Array(energies.indices)
        let audible = inside.filter { energies[$0] > silentEnergy }
        guard !audible.isEmpty else { return Array(energies.indices) }
        // The noise floor: the median of each second's quietest frame. A quiet stretch only
        // drags a few seconds down, so it can't pass for the floor unless it lasts most of the clip.
        let framesPerSecond = 48_000 / hop
        var minima: [Float] = []
        var second = audible[0] / framesPerSecond
        var lowest = Float.infinity
        for f in audible {
            if f / framesPerSecond != second {
                minima.append(lowest)
                second = f / framesPerSecond
                lowest = .infinity
            }
            lowest = min(lowest, energies[f])
        }
        minima.append(lowest)
        let floor = minima.sorted()[minima.count / 2]
        var usable = audible.filter { energies[$0] >= floor * 0.1 }
        if usable.count < 5 { usable = audible }
        return Array(usable.sorted { energies[$0] < energies[$1] }.prefix(max(5, usable.count / 10)))
    }

    /// Frame energy (Σ x² over `frameSize` samples) at or below which a frame counts as digital silence (≈ −100 dBFS).
    static let silentEnergy = Float(frameSize) * 1e-10

    /// Name of the cleaned file for `level`. Files from before the DNS-6 fix were named `nr-…`;
    /// only `nr2-…` files are reused (IMPLEMENTATION §9.4, Reuse).
    public static func fileName(level: NoiseReduction, base: String) -> String { "nr2-\(level.rawValue)-\(base).m4a" }

    /// Whether a recorded cleaned file was made by the current rules and can be reused.
    public static func isCurrent(fileName: String) -> Bool { fileName.hasPrefix("nr2-") }

    /// Pure DSP: one array per channel in, the same out (noise reduced).
    public static func reduce(channels: [[Float]], level: NoiseReduction,
                              progress: (@Sendable (Double) -> Void)? = nil) -> [[Float]] {
        guard let length = channels.first?.count, length > frameSize else { return channels }
        let s = settings(level)
        let n = frameSize, half = n / 2
        let log2n = vDSP_Length(log2(Float(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return channels }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)

        // Pad so every sample is covered by full frames.
        let padded = channels.map { [Float](repeating: 0, count: n) + $0 + [Float](repeating: 0, count: n + hop) }
        let mono: [Float] = padded.count == 1 ? padded[0] : vDSP.multiply(Float(1) / Float(padded.count),
                                                                         padded.dropFirst().reduce(padded[0]) { vDSP.add($0, $1) })
        let frameCount = (mono.count - n) / hop + 1

        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        /// Magnitudes of bins 0...half (DC ... Nyquist) of one windowed frame.
        func spectrum(_ signal: [Float], _ start: Int, into mags: inout [Float]) {
            var frame = [Float](repeating: 0, count: n)
            signal.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            forward(&frame, &re, &im, setup, log2n)
            mags[0] = abs(re[0]); mags[half] = abs(im[0])
            for k in 1..<half { mags[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
        }

        // 1. Noise fingerprint: average spectrum of the quietest 10% of frames.
        var energies = [Float](repeating: 0, count: frameCount)
        mono.withUnsafeBufferPointer { p in
            for f in 0..<frameCount { vDSP_svesq(p.baseAddress! + f * hop, 1, &energies[f], vDSP_Length(n)) }
        }
        let quiet = noiseFrames(energies: energies, length: length)
        var noise = [Float](repeating: 0, count: half + 1)
        var mags = [Float](repeating: 0, count: half + 1)
        for f in quiet {
            spectrum(mono, f * hop, into: &mags)
            vDSP.add(noise, mags, result: &noise)
        }
        vDSP.multiply(Float(1) / Float(quiet.count), noise, result: &noise)

        // 2. Per frame: gains from the mono mix, applied to every channel, overlap-added back.
        var outputs = padded.map { [Float](repeating: 0, count: $0.count) }
        var gains = [Float](repeating: 1, count: half + 1)
        var previous = [Float](repeating: 1, count: half + 1)
        var cre = [Float](repeating: 0, count: half), cim = [Float](repeating: 0, count: half)
        for f in 0..<frameCount {
            let start = f * hop
            spectrum(mono, start, into: &mags)
            for k in 0...half {
                let m = mags[k]
                var g: Float = m > 0 ? 1 - s.oversubtraction * noise[k] / m : 0
                g = max(s.floor, min(1, g))
                // Fast attack, slow release: words come through at once, noise doesn't flutter.
                g = g >= previous[k] ? g : previous[k] * 0.6 + g * 0.4
                gains[k] = g
            }
            previous = gains
            // Light smoothing across neighbouring frequencies.
            var smoothed = gains
            for k in 1..<half { smoothed[k] = (gains[k - 1] + 2 * gains[k] + gains[k + 1]) / 4 }

            for c in padded.indices {
                var frame = [Float](repeating: 0, count: n)
                padded[c].withUnsafeBufferPointer { src in
                    vDSP_vmul(src.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
                }
                forward(&frame, &cre, &cim, setup, log2n)
                cre[0] *= smoothed[0]; cim[0] *= smoothed[half]
                for k in 1..<half { cre[k] *= smoothed[k]; cim[k] *= smoothed[k] }
                inverse(&cre, &cim, into: &frame, setup, log2n)
                // Synthesis window, then overlap-add.
                vDSP.multiply(frame, window, result: &frame)
                outputs[c].withUnsafeMutableBufferPointer { out in
                    vDSP_vadd(out.baseAddress! + start, 1, frame, 1, out.baseAddress! + start, 1, vDSP_Length(n))
                }
            }
            if let progress, f % 256 == 0 { progress(Double(f) / Double(frameCount)) }
        }
        // FFT round trip scales by 2n; Hann² at 75% overlap sums to 1.5.
        let scale = 1 / (Float(2 * n) * 1.5)
        return outputs.map { Array(vDSP.multiply(scale, $0)[n..<(n + length)]) }
    }

    private static func forward(_ frame: inout [Float], _ re: inout [Float], _ im: inout [Float],
                                _ setup: FFTSetup, _ log2n: vDSP_Length) {
        let pairs = vDSP_Length(frame.count / 2)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, pairs)
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private static func inverse(_ re: inout [Float], _ im: inout [Float], into frame: inout [Float],
                                _ setup: FFTSetup, _ log2n: vDSP_Length) {
        let pairs = vDSP_Length(frame.count / 2)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                frame.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, pairs)
                }
            }
        }
    }

    /// Decodes the track to separate Float32 channels; also returns when its first sample plays (seconds).
    private static func read(asset: AVAsset, track: AVAssetTrack, channels: Int,
                             sampleRate: Double) throws -> ([[Float]], Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaImportError.unreadable }
        var interleaved: [Float] = []
        var offset: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if offset == nil { offset = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let start = interleaved.count
            interleaved.append(contentsOf: repeatElement(0, count: bytes / MemoryLayout<Float>.size))
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed { throw reader.error ?? MediaImportError.unreadable }
        let frames = interleaved.count / channels
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        for c in 0..<channels {
            for i in 0..<frames { out[c][i] = interleaved[i * channels + c] }
        }
        let start = offset ?? 0
        return (out, start.isFinite ? start : 0)
    }

    private static func write(_ channels: [[Float]], leadingSilence: Int, sampleRate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let count = channels.count
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(count)) else {
            throw MediaImportError.unreadable
        }
        // Apple Lossless: compact, and no encoder delay to throw the timing off.
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: count,
            AVEncoderBitDepthHintKey: 16,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = (channels.first?.count ?? 0) + leadingSilence
        let chunk = 65_536
        var position = 0
        while position < frames {
            let length = min(chunk, frames - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else { break }
            buffer.frameLength = AVAudioFrameCount(length)
            for c in 0..<count {
                let dst = buffer.floatChannelData![c]
                for i in 0..<length {
                    let src = position + i - leadingSilence
                    dst[i] = src >= 0 ? max(-1, min(1, channels[c][src])) : 0
                }
            }
            try file.write(from: buffer)
            position += length
        }
    }
}
