@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

public enum MediaImportError: Error, Sendable {
    case unsupported
    case noVideoTrack
    case unreadable
}

/// Reads media metadata and prepares files for editing.
public enum MediaImporter {
    /// Copies `url` into the project and returns a populated media item.
    public static func importMedia(at url: URL, store: ProjectStore, projectID: UUID) async throws -> MediaItem {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        let fileName = try store.importFile(at: url, projectID: projectID)
        let stored = store.mediaDirectory(for: projectID).appendingPathComponent(fileName)
        let displayName = url.deletingPathExtension().lastPathComponent
        do {
            if type.conforms(to: .image) {
                return try probeImage(stored, fileName: fileName, displayName: displayName)
            }
            if type.conforms(to: .audio) {
                return try await probeAudio(stored, fileName: fileName, displayName: displayName)
            }
            return try await probeVideo(stored, fileName: fileName, displayName: displayName)
        } catch {
            try? FileManager.default.removeItem(at: stored)
            throw error
        }
    }

    public static func probeVideo(_ url: URL, fileName: String, displayName: String = "") async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            // Audio-only container (e.g. .m4a imported as movie).
            return try await probeAudio(url, fileName: fileName, displayName: displayName)
        }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let turns = quarterTurns(of: transform)
        let upright = turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        var item = MediaItem(kind: .video, fileName: fileName, naturalSize: upright,
                             duration: MediaTime(duration), hasAudio: hasAudio,
                             frameRate: Double(fps > 0 ? fps : 30), displayName: displayName)
        item.sourceQuarterTurns = turns
        return item
    }

    public static func probeAudio(_ url: URL, fileName: String, displayName: String = "") async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw MediaImportError.unsupported }
        let duration = try await asset.load(.duration)
        return MediaItem(kind: .audio, fileName: fileName, naturalSize: .zero, duration: MediaTime(duration),
                         hasAudio: true, displayName: displayName)
    }

    public static func probeImage(_ url: URL, fileName: String, displayName: String = "") throws -> MediaItem {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { throw MediaImportError.unreadable }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        // EXIF orientations 5–8 swap width and height.
        let size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return MediaItem(kind: .photo, fileName: fileName, naturalSize: size, duration: .zero,
                         hasAudio: false, displayName: displayName)
    }

    /// Clockwise quarter turns encoded in a track's preferred transform.
    public static func quarterTurns(of t: CGAffineTransform) -> Int {
        let angle = atan2(Double(t.b), Double(t.a))
        let turns = Int((angle / (Double.pi / 2)).rounded())
        return ((turns % 4) + 4) % 4
    }

    /// Loads an upright, downscaled image for rendering.
    public static func loadImage(_ url: URL, maxPixelSize: Int = 2160) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Extracts one exact frame (upright) from a video.
    public static func frame(of url: URL, at time: MediaTime, maxSize: CGSize = CGSize(width: 2160, height: 2160)) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = maxSize
        return try await generator.image(at: time.cmTime).image
    }
}

/// Generates helper media the engine needs.
public enum UtilityMedia {
    /// A tiny black video used as the base track so the compositor always
    /// receives frame requests (needed for photo-only edits and gaps).
    public static func blackVideoURL() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-black-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw MediaImportError.unreadable }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw MediaImportError.unreadable }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaImportError.unreadable }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    /// Writes a reversed (video-only) copy of `source`.
    ///
    /// Frames are decoded one window at a time (newest window first) so memory
    /// stays bounded for long clips, then re-encoded with the hardware encoder.
    public static func makeReversedVideo(source: URL, destination: URL,
                                         progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaImportError.noVideoTrack }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        try? FileManager.default.removeItem(at: destination)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = duration.seconds
        let window = 1.0
        var windowEnd = total
        var lastWritten = -1.0
        let frameDuration = 1.0 / Double(fps > 0 ? fps : 30)
        while windowEnd > 0.0001 {
            let windowStart = max(0, windowEnd - window)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: windowStart, preferredTimescale: 600),
                                           end: CMTime(seconds: windowEnd, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()
            var frames: [(CVPixelBuffer, Double)] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if t >= windowStart - 0.0001 && t < windowEnd - 0.0001 { frames.append((buffer, t)) }
            }
            for (buffer, t) in frames.reversed() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                // Reversed timestamp, nudged so the first frame starts at zero.
                let reversed = max(0, total - t - frameDuration)
                guard reversed > lastWritten + 0.0005 else { continue }
                lastWritten = reversed
                adaptor.append(buffer, withPresentationTime: CMTime(seconds: reversed, preferredTimescale: 60_000))
            }
            progress?(1 - windowStart / max(total, 0.001))
            windowEnd = windowStart
            try Task.checkCancellation()
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? MediaImportError.unreadable }
    }
}
