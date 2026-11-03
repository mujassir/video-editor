@preconcurrency import AVFoundation
import Photos

public struct ExportSettings: Sendable, Hashable {
    public enum Resolution: Int, CaseIterable, Sendable, Identifiable {
        case p720 = 720, p1080 = 1080, p2160 = 2160
        public var id: Int { rawValue }
        public var label: String {
            switch self {
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p2160: return "4K"
            }
        }
    }
    public enum Codec: String, CaseIterable, Sendable, Identifiable {
        case hevc, h264
        public var id: String { rawValue }
        public var label: String { self == .hevc ? "HEVC" : "H.264" }
    }

    public var resolution: Resolution = .p1080
    public var frameRate: Int = 30
    public var codec: Codec = .hevc

    public init(resolution: Resolution = .p1080, frameRate: Int = 30, codec: Codec = .hevc) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
    }

    var presetName: String {
        codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }
}

public enum ExportError: Error, Sendable {
    case cannotCreateSession
    case failed(String)
}

/// Renders a project to an MP4 file using the hardware encoder.
public enum Exporter {
    public static func export(project: Project, resolver: MediaResolver, settings: ExportSettings,
                              to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var project = project
        project.frameRate = settings.frameRate
        let size = project.aspectRatio.renderSize(shortEdge: settings.resolution.rawValue)
        let built = try await CompositionBuilder().build(project: project, resolver: resolver,
                                                         renderSize: size, quality: .export)
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: settings.presetName) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        progress(1)
    }

    /// Saves an exported file to the Photos library.
    public static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.failed("Photos access denied") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    /// Renders the edit's mixed audio (in timeline time) to an .m4a file – used for analysis.
    public static func exportAudio(project: Project, resolver: MediaResolver, to url: URL,
                                   includeFreeAudio: Bool = false) async throws {
        var project = project
        if !includeFreeAudio { project.audioClips.removeAll { $0.role == .music || $0.role == .effect } }
        let built = try await CompositionBuilder().build(project: project, resolver: resolver,
                                                         renderSize: CGSize(width: 64, height: 64))
        try? FileManager.default.removeItem(at: url)
        // Audio-only export of the mixed tracks.
        let audioOnly = AVMutableComposition()
        for track in try await built.composition.loadTracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            guard range.duration > .zero,
                  let t = audioOnly.addMutableTrack(withMediaType: .audio, preferredTrackID: track.trackID) else { continue }
            try t.insertTimeRange(range, of: track, at: range.start)
        }
        guard !(try await audioOnly.loadTracks(withMediaType: .audio)).isEmpty else {
            throw ExportError.failed("No audio in this edit")
        }
        guard let session = AVAssetExportSession(asset: audioOnly, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.cannotCreateSession
        }
        let mix = AVMutableAudioMix()
        var params: [AVAudioMixInputParameters] = []
        for p in built.audioMix.inputParameters {
            let np = AVMutableAudioMixInputParameters()
            np.trackID = p.trackID
            var t = CMTime.zero
            var range = CMTimeRange()
            var start: Float = 1, end: Float = 1
            while p.getVolumeRamp(for: t, startVolume: &start, endVolume: &end, timeRange: &range) {
                np.setVolumeRamp(fromStartVolume: start, toEndVolume: end, timeRange: range)
                t = range.end
                if range.duration == .zero { break }
            }
            params.append(np)
        }
        mix.inputParameters = params
        session.audioMix = mix
        try await session.export(to: url, as: .m4a)
    }
}
