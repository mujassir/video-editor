@preconcurrency import AVFoundation
import Accelerate
import CoreGraphics

/// Generates and caches filmstrip thumbnails for the timeline.
public actor ThumbnailProvider {
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private let capacity = 600
    private var generators: [URL: AVAssetImageGenerator] = [:]

    public init() {}

    private func generator(for url: URL, height: CGFloat) -> AVAssetImageGenerator {
        if let g = generators[url] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: height * 3, height: height * 2)
        // Scrubbing thumbnails don't need exact frames – tolerance makes them much faster.
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        generators[url] = g
        return g
    }

    private func key(_ url: URL, _ time: MediaTime) -> String {
        // Quantize to 1/4 s so nearby requests share a thumbnail.
        "\(url.lastPathComponent)@\(time.ticks / (MediaTime.timescale / 4))"
    }

    public func cached(_ url: URL, at time: MediaTime) -> CGImage? { cache[key(url, time)] }

    /// Thumbnails for a set of times, generated in one batch.
    public func thumbnails(_ url: URL, times: [MediaTime], height: CGFloat = 120) async -> [MediaTime: CGImage] {
        var result: [MediaTime: CGImage] = [:]
        var missing: [MediaTime] = []
        for t in times {
            if let img = cache[key(url, t)] { result[t] = img } else { missing.append(t) }
        }
        guard !missing.isEmpty else { return result }
        let g = generator(for: url, height: height)
        for await item in g.images(for: missing.map(\.cmTime)) {
            guard let image = try? item.image else { continue }
            let requested = MediaTime(item.requestedTime)
            store(key(url, requested), image)
            result[requested] = image
        }
        return result
    }

    private func store(_ k: String, _ image: CGImage) {
        if cache[k] == nil { order.append(k) }
        cache[k] = image
        if order.count > capacity {
            let drop = order.removeFirst()
            cache[drop] = nil
        }
    }
}

/// Peak-amplitude waveform for drawing audio lanes.
public enum Waveform {
    /// Returns `buckets` normalized peaks (0...1) across the file (or a range).
    public static func peaks(url: URL, buckets: Int, range: MediaTimeRange? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let samples = try readMono(asset: asset, track: track, sampleRate: 8000, range: range)
        return bucketPeaks(samples, buckets: buckets)
    }

    public static func bucketPeaks(_ samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0, !samples.isEmpty else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        let per = Double(samples.count) / Double(buckets)
        samples.withUnsafeBufferPointer { ptr in
            for b in 0..<buckets {
                let start = Int(Double(b) * per)
                let end = min(samples.count, max(start + 1, Int(Double(b + 1) * per)))
                var peak: Float = 0
                vDSP_maxmgv(ptr.baseAddress! + start, 1, &peak, vDSP_Length(end - start))
                peaks[b] = peak
            }
        }
        let maxPeak = peaks.max() ?? 1
        if maxPeak > 0 { vDSP.multiply(1 / maxPeak, peaks, result: &peaks) }
        return peaks
    }

    /// Decodes an audio track to mono Float32 at `sampleRate`.
    public static func readMono(asset: AVAsset, track: AVAssetTrack, sampleRate: Double,
                                range: MediaTimeRange? = nil, audioMix: AVAudioMix? = nil) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range.cmTimeRange }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaImportError.unreadable }
        return drain(output)
    }

    /// Decodes several tracks mixed together (e.g. a composition's audio) to mono Float32.
    public static func readMixedMono(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?,
                                     sampleRate: Double) throws -> [Float] {
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaImportError.unreadable }
        return drain(output)
    }

    private static func drain(_ output: AVAssetReaderOutput) -> [Float] {
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        return samples
    }
}
