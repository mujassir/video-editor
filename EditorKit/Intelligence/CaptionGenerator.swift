@preconcurrency import AVFoundation
@preconcurrency import Speech

public enum CaptionError: Error, Sendable, LocalizedError {
    case noSpeechFound
    case recognizerUnavailable
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .noSpeechFound: return "No speech was found in this video."
        case .recognizerUnavailable: return "On-device speech recognition isn't available for this language."
        case .notAuthorized: return "Speech recognition permission is needed to create captions."
        }
    }
}

/// On-device transcription → word-timed caption segments.
///
/// Uses iOS 26's SpeechAnalyzer/SpeechTranscriber (fast, long-form, fully on
/// device). Falls back to SFSpeechRecognizer with on-device recognition forced.
public enum CaptionGenerator {
    public enum Engine: String, Sendable { case speechAnalyzer, sfSpeech }

    /// Transcribes an audio file into words with timestamps (seconds from file start).
    public static func transcribe(url: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> (words: [CaptionWord], engine: Engine) {
        do {
            let words = try await transcribeWithAnalyzer(url: url, locale: locale)
            if !words.isEmpty { return (words, .speechAnalyzer) }
        } catch {
            // Fall through to the legacy on-device recognizer.
        }
        let words = try await transcribeWithSFSpeech(url: url, locale: locale)
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
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw CaptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw CaptionError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error { finished = true; c.resume(throwing: error); return }
                if let result, result.isFinal { finished = true; c.resume(returning: result) }
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

    /// Full pipeline: mix the edit's speech, transcribe on device, place captions on the timeline.
    public static func generate(project: Project, resolver: MediaResolver, workDirectory: URL,
                                locale: Locale = Locale(identifier: "en-US")) async throws -> (CaptionTrack, Engine) {
        let audioURL = workDirectory.appendingPathComponent("caption-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try await Exporter.exportAudio(project: project, resolver: resolver, to: audioURL)
        let (words, engine) = try await transcribe(url: audioURL, locale: locale)
        guard !words.isEmpty else { throw CaptionError.noSpeechFound }
        var track = project.captions
        track.segments = segments(from: words)
        track.isVisible = true
        return (track, engine)
    }
}
