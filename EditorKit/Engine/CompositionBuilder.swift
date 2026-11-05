@preconcurrency import AVFoundation
import CoreGraphics

/// Resolves project media to files on disk.
public struct MediaResolver: Sendable {
    public let mediaDirectory: URL
    public init(mediaDirectory: URL) { self.mediaDirectory = mediaDirectory }
    public init(store: ProjectStore, projectID: UUID) { self.mediaDirectory = store.mediaDirectory(for: projectID) }

    public func url(for item: MediaItem) -> URL { mediaDirectory.appendingPathComponent(item.fileName) }
    public func reversedURL(for item: MediaItem) -> URL? {
        item.reversedFileName.map { mediaDirectory.appendingPathComponent($0) }
    }
}

/// The playable / exportable result of building a project.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let scene: RenderScene
    public let duration: MediaTime
}

public enum CompositionError: Error, Sendable {
    case empty
    case missingMedia(String)
}

/// Turns a `Project` into an AVComposition + custom video composition.
///
/// Main-track clips alternate between two video tracks (A/B roll) so that
/// clips can overlap during transitions; the compositor blends them.
public final class CompositionBuilder: @unchecked Sendable {
    private var assets: [URL: AVURLAsset] = [:]
    private var stillCache: [String: CGImage] = [:]

    public init() {}

    private func asset(_ url: URL) -> AVURLAsset {
        if let a = assets[url] { return a }
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[url] = a
        return a
    }

    public func build(project: Project, resolver: MediaResolver, renderSize: CGSize,
                      quality: RenderQuality = .preview,
                      toggles: RenderToggles = RenderToggles()) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        let layout = project.layout
        let total = project.duration
        guard total > .zero else { throw CompositionError.empty }

        // Base track: a black clip stretched over the whole edit keeps the compositor fed.
        let blackURL = try await UtilityMedia.blackVideoURL()
        let blackAsset = asset(blackURL)
        if let blackTrack = try await blackAsset.loadTracks(withMediaType: .video).first,
           let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let blackDuration = try await blackAsset.load(.duration)
            try base.insertTimeRange(CMTimeRange(start: .zero, duration: blackDuration), of: blackTrack, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: blackDuration), toDuration: total.cmTime)
        }

        let videoTracks = [composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                           composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)]
        // Created on demand for slowed clips (A/B like the main tracks).
        var blendTracks: [AVMutableCompositionTrack?] = [nil, nil]
        let audioTracks = [composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                           composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)]
        var audioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for track in audioTracks.compactMap({ $0 }) {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            p.setVolume(1, at: .zero)
            audioParams[track.trackID] = p
        }

        var infos: [ClipRenderInfo] = []
        var stills: [UUID: CGImage] = [:]

        for entry in layout.entries {
            let clip = project.clips[entry.index]
            guard let media = project.mediaItem(clip.mediaID) else { throw CompositionError.missingMedia("\(clip.mediaID)") }
            let lane = entry.index % 2
            let timelineStart = entry.range.start.cmTime
            let timelineDuration = entry.range.duration.cmTime
            var trackID: CMPersistentTrackID?
            var blendTrackID: CMPersistentTrackID?
            var blendFileStart = 0.0
            var blendFPS = 30.0

            if clip.isStill {
                let url = resolver.url(for: media)
                let key = "\(media.id)-\(clip.freezeAt?.ticks ?? -1)"
                if let cached = stillCache[key] {
                    stills[clip.id] = cached
                } else {
                    let image: CGImage?
                    if let freezeAt = clip.freezeAt {
                        image = try? await MediaImporter.frame(of: url, at: freezeAt)
                    } else {
                        image = MediaImporter.loadImage(url)
                    }
                    if let image {
                        stillCache[key] = image
                        stills[clip.id] = image
                    }
                }
            } else {
                var sourceURL = resolver.url(for: media)
                var sourceRange = clip.sourceRange.cmTimeRange
                if clip.isReversed {
                    guard let reversed = resolver.reversedURL(for: media),
                          FileManager.default.fileExists(atPath: reversed.path) else {
                        throw CompositionError.missingMedia("reversed \(media.fileName)")
                    }
                    // Source time t in the original is (duration - t) in the reversed file.
                    sourceURL = reversed
                    let start = media.duration - clip.sourceRange.end
                    sourceRange = CMTimeRange(start: start.cmTime, duration: clip.sourceRange.duration.cmTime)
                }
                let a = asset(sourceURL)
                guard let srcVideo = try await a.loadTracks(withMediaType: .video).first,
                      let track = videoTracks[lane] else {
                    throw CompositionError.missingMedia(media.fileName)
                }
                try track.insertTimeRange(sourceRange, of: srcVideo, at: timelineStart)
                if clip.speed != 1 {
                    track.scaleTimeRange(CMTimeRange(start: timelineStart, duration: sourceRange.duration),
                                         toDuration: timelineDuration)
                }
                trackID = track.trackID

                // Smooth slow motion: the same footage one source frame ahead on a blend track.
                let fps = media.frameRate > 1 ? media.frameRate : 30
                let frame = CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
                if clip.speed < 0.95, sourceRange.duration > frame + frame {
                    if blendTracks[lane] == nil {
                        blendTracks[lane] = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    if let blend = blendTracks[lane] {
                        let ahead = CMTimeRange(start: sourceRange.start + frame, duration: sourceRange.duration - frame)
                        try blend.insertTimeRange(ahead, of: srcVideo, at: timelineStart)
                        blend.scaleTimeRange(CMTimeRange(start: timelineStart, duration: ahead.duration),
                                             toDuration: CMTimeMultiplyByFloat64(ahead.duration, multiplier: 1 / clip.speed))
                        blendTrackID = blend.trackID
                        blendFileStart = sourceRange.start.seconds
                        blendFPS = fps
                    }
                }

                if !clip.isReversed, !clip.isMuted, clip.volume > 0, media.hasAudio,
                   let srcAudio = try await a.loadTracks(withMediaType: .audio).first,
                   let audio = audioTracks[lane] {
                    try audio.insertTimeRange(sourceRange, of: srcAudio, at: timelineStart)
                    if clip.speed != 1 {
                        audio.scaleTimeRange(CMTimeRange(start: timelineStart, duration: sourceRange.duration),
                                             toDuration: timelineDuration)
                    }
                    if let params = audioParams[audio.trackID] {
                        let vol = Float(clip.volume)
                        // Crossfade audio across transitions.
                        if entry.overlapIn > .zero {
                            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol,
                                                 timeRange: CMTimeRange(start: timelineStart, duration: entry.overlapIn.cmTime))
                        } else {
                            params.setVolume(vol, at: timelineStart)
                        }
                        if entry.overlapOut > .zero {
                            let start = (entry.range.end - entry.overlapOut).cmTime
                            params.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0,
                                                 timeRange: CMTimeRange(start: start, duration: entry.overlapOut.cmTime))
                        }
                    }
                }
            }

            let previous = entry.index > 0 ? project.clips[entry.index - 1] : nil
            var info = ClipRenderInfo(clip: clip, media: media, trackID: trackID,
                                      timelineRange: entry.range, overlapIn: entry.overlapIn, overlapOut: entry.overlapOut,
                                      transitionIn: entry.overlapIn > .zero ? previous?.transitionOut : nil,
                                      transitionOut: entry.overlapOut > .zero ? clip.transitionOut : nil)
            info.blendTrackID = blendTrackID
            info.blendFileStart = blendFileStart
            info.blendFPS = blendFPS
            infos.append(info)
        }

        // Free audio clips each get their own track so volume envelopes stay independent.
        let speech = Self.speechRanges(project)
        for clip in project.audioClips {
            guard let media = project.mediaItem(clip.mediaID) else { continue }
            let a = asset(resolver.url(for: media))
            guard let src = try await a.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let p = AVMutableAudioMixInputParameters(track: track)
            if clip.hasSectionEdits {
                // Kept sections play back to back (deleted ones are cut out), each at its own volume.
                var cursor = clip.start
                var placed: [(range: MediaTimeRange, volume: Float)] = []
                for s in clip.resolvedSections where !s.deleted {
                    guard cursor < total else { break }
                    let len = min(s.duration, total - cursor)
                    guard len > .zero else { continue }
                    try track.insertTimeRange(MediaTimeRange(start: s.start, duration: len).cmTimeRange, of: src, at: cursor.cmTime)
                    placed.append((MediaTimeRange(start: cursor, duration: len), Float(clip.volume * s.volume)))
                    cursor += len
                }
                guard !placed.isEmpty else { continue }
                Self.applySectionEnvelope(to: p, sections: placed, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
            } else {
                let available = min(clip.sourceRange.duration, total - clip.start)
                guard available > .zero else { continue }
                let range = MediaTimeRange(start: clip.sourceRange.start, duration: available)
                try track.insertTimeRange(range.cmTimeRange, of: src, at: clip.start.cmTime)
                Self.applyEnvelope(to: p, clip: clip, playedDuration: available, speech: clip.autoDuck ? speech : [])
            }
            audioParams[track.trackID] = p
        }

        // Instructions: split the timeline wherever the set of visible clips changes.
        var boundaries = Set<MediaTime>([.zero, total])
        for info in infos {
            boundaries.insert(info.timelineRange.start)
            boundaries.insert(min(info.timelineRange.end, total))
        }
        let scene = RenderScene(renderSize: renderSize, background: project.background, quality: quality,
                                clips: infos, texts: project.textOverlays, captions: project.captions, stills: stills,
                                toggles: toggles, watermark: project.watermark,
                                watermarkImage: project.watermark.flatMap { w in
                                    guard w.kind == .image, let name = w.imageFileName else { return nil }
                                    return MediaImporter.loadImage(resolver.mediaDirectory.appendingPathComponent(name), maxPixelSize: 1024)
                                })
        let sorted = boundaries.sorted()
        var instructions: [RenderInstruction] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            let mid = MediaTime(ticks: (a.ticks + b.ticks) / 2)
            let visible = infos.indices.filter { infos[$0].timelineRange.contains(mid) }
            instructions.append(RenderInstruction(timeRange: MediaTimeRange(start: a, end: b).cmTimeRange,
                                                  scene: scene, clipIndices: visible))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = VideoCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.frameRate))
        videoComposition.instructions = instructions

        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(audioParams.values)

        return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                audioMix: mix, scene: scene, duration: total)
    }

    /// Timeline ranges where someone is speaking (from captions), used for ducking.
    static func speechRanges(_ project: Project) -> [MediaTimeRange] {
        Project.merge(project.captions.segments.map { seg in
            MediaTimeRange(start: seg.range.start - MediaTime(seconds: 0.15), end: seg.range.end + MediaTime(seconds: 0.25))
        })
    }

    /// Volume envelope: fades in/out plus optional ducking under speech.
    /// Per-section volumes (in timeline order) with an optional fade at the very start and end.
    static func applySectionEnvelope(to p: AVMutableAudioMixInputParameters,
                                     sections: [(range: MediaTimeRange, volume: Float)],
                                     fadeIn: MediaTime, fadeOut: MediaTime) {
        p.setVolume(sections[0].volume, at: .zero)
        for (k, s) in sections.enumerated() {
            let isFirst = k == 0, isLast = k == sections.count - 1
            let inLen = isFirst ? min(fadeIn, s.range.duration) : .zero
            let outLen = isLast ? min(fadeOut, s.range.duration - inLen) : .zero
            if inLen > .zero {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: s.volume,
                                timeRange: MediaTimeRange(start: s.range.start, duration: inLen).cmTimeRange)
            } else {
                p.setVolume(s.volume, at: s.range.start.cmTime)
            }
            if outLen > .zero {
                p.setVolumeRamp(fromStartVolume: s.volume, toEndVolume: 0,
                                timeRange: MediaTimeRange(start: s.range.end - outLen, duration: outLen).cmTimeRange)
            }
        }
    }

    static func applyEnvelope(to p: AVMutableAudioMixInputParameters, clip: AudioClip, playedDuration: MediaTime,
                              speech: [MediaTimeRange], duckLevel: Double = 0.25) {
        let vol = Float(clip.volume)
        let start = clip.start
        let end = clip.start + playedDuration
        let ramp = MediaTime(seconds: 0.2)
        p.setVolume(vol, at: .zero)
        if clip.fadeIn > .zero {
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol,
                            timeRange: MediaTimeRange(start: start, duration: min(clip.fadeIn, playedDuration)).cmTimeRange)
        }
        for s in speech {
            guard let r = s.intersection(MediaTimeRange(start: start + clip.fadeIn, end: end - clip.fadeOut)),
                  r.duration > ramp + ramp else { continue }
            let low = vol * Float(duckLevel)
            p.setVolumeRamp(fromStartVolume: vol, toEndVolume: low,
                            timeRange: MediaTimeRange(start: r.start, duration: ramp).cmTimeRange)
            p.setVolumeRamp(fromStartVolume: low, toEndVolume: low,
                            timeRange: MediaTimeRange(start: r.start + ramp, end: r.end - ramp).cmTimeRange)
            p.setVolumeRamp(fromStartVolume: low, toEndVolume: vol,
                            timeRange: MediaTimeRange(start: r.end - ramp, duration: ramp).cmTimeRange)
        }
        if clip.fadeOut > .zero {
            let d = min(clip.fadeOut, playedDuration)
            p.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0,
                            timeRange: MediaTimeRange(start: end - d, duration: d).cmTimeRange)
        }
    }
}
