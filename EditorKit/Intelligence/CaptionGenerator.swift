@preconcurrency import AVFoundation
@preconcurrency import Speech

public enum CaptionError: Error, Sendable, LocalizedError {
    case noSpeechFound
    case recognizerUnavailable
    case notAuthorized
    case timedOut(onDevice: Bool)
    case stageTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .noSpeechFound: return "No speech was found in this video."
        case .recognizerUnavailable: return "On-device speech recognition isn't available for this language."
        case .notAuthorized: return "Speech recognition permission is needed to create captions."
        case .stageTimedOut(let stage): return "Speech recognition stalled at: \(stage)."
        case .timedOut(let onDevice): return "Speech recognition timed out (on-device model \(onDevice ? "present" : "not available"))."
        }
    }
}

/// On-device transcription → word-timed caption segments.
///
/// Uses iOS 26's SpeechAnalyzer/SpeechTranscriber (fast, long-form, fully on
/// device). Falls back to SFSpeechRecognizer with on-device recognition forced.
public enum CaptionGenerator {
    public enum Engine: String, Sendable { case speechAnalyzer, sfSpeech }

    /// Why the SpeechAnalyzer path was skipped on the last run (diagnostics).
    nonisolated(unsafe) public static var lastAnalyzerFailure: String?

    /// Transcribes an audio file into words with timestamps (seconds from file start).
    /// Runs `work`, failing with `stageTimedOut(stage)` if it takes longer than `seconds`.
    /// Unstructured on purpose: a hung system callback can't block the caller.
    static func withTimeout<T: Sendable>(_ seconds: Double, stage: String,
                                         _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let task = Task {
                do {
                    let value = try await work()
                    if once.claim() { c.resume(returning: value) }
                } catch {
                    if once.claim() { c.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    task.cancel()
                    c.resume(throwing: CaptionError.stageTimedOut(stage))
                }
            }
        }
    }

    public static func transcribe(url: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> (words: [CaptionWord], engine: Engine) {
        do {
            let words = try await withTimeout(90, stage: "SpeechAnalyzer") { try await transcribeWithAnalyzer(url: url, locale: locale) }
            if !words.isEmpty { return (words, .speechAnalyzer) }
            lastAnalyzerFailure = "no words"
        } catch {
            // Fall through to the legacy on-device recognizer.
            lastAnalyzerFailure = String(describing: error)
        }
        let words = try await withTimeout(120, stage: "SFSpeechRecognizer") { try await transcribeWithSFSpeech(url: url, locale: locale) }
        return (words, .sfSpeech)
    }

    static func transcribeWithAnalyzer(url: URL, locale: Locale) async throws -> [CaptionWord] {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CaptionError.recognizerUnavailable
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        let collector = Task { () throws -> [CaptionWord] in
            var words: [CaptionWord] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(text[run.range].characters)
                    words.append(contentsOf: splitRun(piece, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    static func transcribeWithSFSpeech(url: URL, locale: Locale) async throws -> [CaptionWord] {
        let status = try await withTimeout(20, stage: "speech permission") {
            await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw CaptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw CaptionError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let audioSeconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 30
        let onDevice = recognizer.supportsOnDeviceRecognition
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var task: SFSpeechRecognitionTask?
            func finish() -> Bool { lock.lock(); defer { lock.unlock() }; if finished { return false }; finished = true; return true }
        }
        let box = Box()
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let error { if box.finish() { c.resume(throwing: error) }; return }
                if let result, result.isFinal, box.finish() { c.resume(returning: result) }
            }
            // Never hang the UI: give up after a generous multiple of the audio length.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30 + audioSeconds * 3) {
                if box.finish() {
                    box.task?.cancel()
                    c.resume(throwing: CaptionError.timedOut(onDevice: onDevice))
                }
            }
        }
        return result.bestTranscription.segments.map {
            CaptionWord(text: $0.substring,
                        range: MediaTimeRange(start: MediaTime(seconds: $0.timestamp),
                                              duration: MediaTime(seconds: max($0.duration, 0.05))))
        }
    }

    /// A run may hold several words; spread its time across them by length.
    static func splitRun(_ text: String, start: Double, end: Double) -> [CaptionWord] {
        let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else { return [] }
        let totalChars = Double(pieces.reduce(0) { $0 + $1.count })
        var cursor = start
        return pieces.map { piece in
            let share = (end - start) * Double(piece.count) / max(totalChars, 1)
            let word = CaptionWord(text: piece, range: MediaTimeRange(start: MediaTime(seconds: cursor),
                                                                     duration: MediaTime(seconds: max(share, 0.04))))
            cursor += share
            return word
        }
    }

    /// Groups words into short on-screen captions.
    public static func segments(from words: [CaptionWord], maxWords: Int = 5, maxDuration: Double = 2.6,
                                pauseBreak: Double = 0.55) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        var current: [CaptionWord] = []
        func flush() {
            if !current.isEmpty { segments.append(CaptionSegment(words: current)) }
            current = []
        }
        for word in words {
            if let last = current.last {
                let gap = (word.range.start - last.range.end).seconds
                let span = (word.range.end - current[0].range.start).seconds
                let sentenceEnd = last.text.last.map { ".!?".contains($0) } ?? false
                if current.count >= maxWords || span > maxDuration || gap > pauseBreak || sentenceEnd { flush() }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Mixes the edit's speech (main track + voiceovers, no music) to 16 kHz mono PCM, in timeline time.
    static func writeSpeechMix(project: Project, resolver: MediaResolver, to url: URL) async throws {
        var speechOnly = project
        speechOnly.audioClips.removeAll { $0.role == .music || $0.role == .effect }
        let built = try await CompositionBuilder().build(project: speechOnly, resolver: resolver,
                                                         renderSize: CGSize(width: 64, height: 64))
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw CaptionError.noSpeechFound }
        let sampleRate = 16_000.0
        let samples = try Waveform.readMixedMono(asset: built.composition, tracks: tracks,
                                                 audioMix: built.audioMix, sampleRate: sampleRate)
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CaptionError.noSpeechFound
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Full pipeline: mix the edit's speech, transcribe on device, place captions on the timeline.
    public static func generate(project: Project, resolver: MediaResolver, workDirectory: URL,
                                locale: Locale = Locale(identifier: "en-US")) async throws -> (CaptionTrack, Engine) {
        let audioURL = workDirectory.appendingPathComponent("caption-audio-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try await withTimeout(60, stage: "audio mixdown") { try await writeSpeechMix(project: project, resolver: resolver, to: audioURL) }
        let (words, engine) = try await transcribe(url: audioURL, locale: locale)
        guard !words.isEmpty else { throw CaptionError.noSpeechFound }
        var track = project.captions
        track.segments = segments(from: words)
        track.isVisible = true
        return (track, engine)
    }
}

/// Resolves a race exactly once (used by timeouts).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
