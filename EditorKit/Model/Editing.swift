import Foundation

public enum EditError: Error, Equatable, Sendable {
    case clipNotFound
    case tooShort
    case outOfRange
}

/// Pure, value-type editing operations on a project.
///
/// Every operation returns a new project (or throws) so the editor can keep
/// cheap snapshots for undo/redo, and every operation is unit-testable.
public extension Project {
    /// Shortest clip the editor will produce.
    static let minimumClipDuration = MediaTime(seconds: 0.1)

    // MARK: Adding media

    /// Appends media to the main track (photos default to 3 s).
    mutating func appendClip(for item: MediaItem, photoDuration: MediaTime = MediaTime(seconds: 3)) {
        if !media.contains(where: { $0.id == item.id }) { media.append(item) }
        defer {
            // New visual clips follow the project's canvas fit setting.
            if item.kind != .audio, let last = clips.indices.last {
                if let fit = defaultFit { clips[last].transform.fit = fit }
                if let anchor = defaultAnchor { clips[last].transform.anchor = anchor }
            }
        }
        switch item.kind {
        case .video:
            clips.append(VideoClip(mediaID: item.id, kind: .video,
                                   sourceRange: MediaTimeRange(start: .zero, duration: item.duration)))
        case .photo:
            clips.append(VideoClip(mediaID: item.id, kind: .photo,
                                   sourceRange: MediaTimeRange(start: .zero, duration: photoDuration)))
        case .audio:
            let clip = AudioClip(mediaID: item.id, role: .music,
                                 sourceRange: MediaTimeRange(start: .zero, duration: item.duration),
                                 start: .zero)
            addAudio(clip)
        }
    }

    mutating func addAudio(_ clip: AudioClip) {
        var clip = clip
        // Put it on the first lane where it does not collide.
        var lane = 0
        while audioClips.contains(where: { $0.lane == lane && $0.timelineRange.intersection(clip.timelineRange) != nil }) {
            lane += 1
        }
        clip.lane = lane
        audioClips.append(clip)
    }

    // MARK: Split

    /// Splits the main-track clip under `time` into two clips. Returns the new (right-hand) clip's id.
    @discardableResult
    mutating func split(at time: MediaTime) throws -> UUID {
        let layout = self.layout
        guard let entry = layout.entry(at: time) else { throw EditError.outOfRange }
        let local = time - entry.range.start
        let duration = entry.range.duration
        guard local >= Self.minimumClipDuration, duration - local >= Self.minimumClipDuration else {
            throw EditError.tooShort
        }
        let original = clips[entry.index]
        var left = original
        var right = original
        right.id = UUID()
        left.transitionOut = nil

        if original.isStill {
            left.sourceRange.duration = local
            right.sourceRange.duration = duration - local
        } else {
            let sourceLocal = local.multiplied(by: original.speed)
            if original.isReversed {
                // Reversed clips play from source end towards source start.
                let splitPoint = original.sourceRange.end - sourceLocal
                left.sourceRange = MediaTimeRange(start: splitPoint, end: original.sourceRange.end)
                right.sourceRange = MediaTimeRange(start: original.sourceRange.start, end: splitPoint)
            } else {
                let splitPoint = original.sourceRange.start + sourceLocal
                left.sourceRange = MediaTimeRange(start: original.sourceRange.start, end: splitPoint)
                right.sourceRange = MediaTimeRange(start: splitPoint, end: original.sourceRange.end)
            }
            left.reframe = original.reframe.filter { left.sourceRange.contains($0.time) }
            right.reframe = original.reframe.filter { right.sourceRange.contains($0.time) }
        }
        clips[entry.index] = left
        clips.insert(right, at: entry.index + 1)
        return right.id
    }

    // MARK: Trim

    enum TrimEdge: Sendable { case leading, trailing }

    /// Moves a clip edge by `delta` timeline time. Positive delta moves the edge right.
    /// The result is clamped to the source media and the minimum clip length.
    mutating func trim(clipID: UUID, edge: TrimEdge, by delta: MediaTime) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        var clip = clips[index]
        guard let item = mediaItem(clip.mediaID) else { throw EditError.clipNotFound }
        let minSource = clip.isStill ? Self.minimumClipDuration : Self.minimumClipDuration.multiplied(by: clip.speed)

        if clip.isStill {
            // Stills can be any length; only trailing/leading shorten or lengthen.
            let change = edge == .trailing ? delta : MediaTime.zero - delta
            let newDuration = max(clip.sourceRange.duration + change, minSource)
            clip.sourceRange.duration = min(newDuration, MediaTime(seconds: 60))
            clips[index] = clip
            return
        }

        let sourceDelta = delta.multiplied(by: clip.speed)
        var start = clip.sourceRange.start
        var end = clip.sourceRange.end
        // On the timeline, a reversed clip's leading edge is its source end.
        let movesSourceStart = (edge == .leading) != clip.isReversed
        if movesSourceStart {
            start = start + (clip.isReversed ? MediaTime.zero - sourceDelta : sourceDelta)
            start = start.clamped(to: .zero...(end - minSource))
        } else {
            end = end + (clip.isReversed ? MediaTime.zero - sourceDelta : sourceDelta)
            end = end.clamped(to: (start + minSource)...item.duration)
        }
        clip.sourceRange = MediaTimeRange(start: start, end: end)
        clip.reframe = clip.reframe.filter { clip.sourceRange.contains($0.time) }
        clips[index] = clip
    }

    /// Sets the clip's source range directly (used by the precise trim panel).
    mutating func setSourceRange(clipID: UUID, _ range: MediaTimeRange) throws {
        guard let index = clipIndex(clipID), let item = mediaItem(clips[index].mediaID) else {
            throw EditError.clipNotFound
        }
        let start = range.start.clamped(to: .zero...item.duration)
        let end = range.end.clamped(to: start...item.duration)
        guard end - start >= Self.minimumClipDuration else { throw EditError.tooShort }
        clips[index].sourceRange = MediaTimeRange(start: start, end: end)
    }

    // MARK: Delete / duplicate / move

    mutating func deleteClip(_ clipID: UUID) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        clips.remove(at: index)
        if index > 0, index == clips.count { clips[index - 1].transitionOut = nil }
    }

    @discardableResult
    mutating func duplicateClip(_ clipID: UUID) throws -> UUID {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        var copy = clips[index]
        copy.id = UUID()
        clips.insert(copy, at: index + 1)
        return copy.id
    }

    mutating func moveClip(_ clipID: UUID, to newIndex: Int) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        let clip = clips.remove(at: index)
        clips.insert(clip, at: max(0, min(newIndex, clips.count)))
        if let last = clips.indices.last { clips[last].transitionOut = nil }
    }

    // MARK: Speed / reverse / freeze

    mutating func setSpeed(_ speed: Double, clipID: UUID) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        guard !clips[index].isStill else { return }
        clips[index].speed = min(max(speed, 0.1), 10)
    }

    mutating func setReversed(_ reversed: Bool, clipID: UUID) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        guard clips[index].kind == .video, clips[index].freezeAt == nil else { return }
        clips[index].isReversed = reversed
    }

    /// Inserts a still frame of the clip under `time`, splitting the clip around it.
    @discardableResult
    mutating func insertFreezeFrame(at time: MediaTime, duration: MediaTime = MediaTime(seconds: 1.5)) throws -> UUID {
        let layout = self.layout
        guard let entry = layout.entry(at: time) else { throw EditError.outOfRange }
        let clip = clips[entry.index]
        guard clip.kind == .video, clip.freezeAt == nil else { throw EditError.outOfRange }
        let local = time - entry.range.start
        let sourceTime = clip.sourceTime(atClipTime: local)

        var freeze = clip
        freeze.id = UUID()
        freeze.freezeAt = sourceTime
        freeze.sourceRange = MediaTimeRange(start: sourceTime, duration: duration)
        freeze.transitionOut = nil
        freeze.isReversed = false
        freeze.speed = 1
        freeze.reframe = []

        if local < Self.minimumClipDuration {
            clips.insert(freeze, at: entry.index)
        } else if entry.range.duration - local < Self.minimumClipDuration {
            clips.insert(freeze, at: entry.index + 1)
        } else {
            try split(at: time)
            clips.insert(freeze, at: entry.index + 1)
        }
        return freeze.id
    }

    // MARK: Per-clip settings

    mutating func updateClip(_ clipID: UUID, _ change: (inout VideoClip) -> Void) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        change(&clips[index])
    }

    static let stillDurationRange = MediaTime(seconds: 0.5)...MediaTime(seconds: 30)

    /// Sets how long a photo / freeze frame shows (0.5–30 s); optionally for every photo.
    mutating func setStillDuration(_ duration: MediaTime, clipID: UUID, allPhotos: Bool = false) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        guard clips[index].isStill else { return }
        let d = duration.clamped(to: Self.stillDurationRange)
        if allPhotos {
            for i in clips.indices where clips[i].kind == .photo { clips[i].sourceRange.duration = d }
        }
        clips[index].sourceRange.duration = d
    }

    /// Canvas-wide fit: applies to every clip and to clips added later.
    mutating func setContentFit(_ fit: ContentFit, anchor: ContentAnchor) {
        defaultFit = fit
        defaultAnchor = anchor
        for i in clips.indices {
            clips[i].transform.fit = fit
            clips[i].transform.anchor = anchor
        }
    }

    /// Sets the motion on one still clip, or on every photo when `allPhotos` is true.
    mutating func setPhotoMotion(_ motion: PhotoMotion?, clipID: UUID, allPhotos: Bool = false) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        guard clips[index].isStill else { return }
        let value = motion == PhotoMotion.none ? nil : motion
        if allPhotos {
            for i in clips.indices where clips[i].kind == .photo { clips[i].photoMotion = value }
        }
        clips[index].photoMotion = value
    }

    mutating func setTransition(_ transition: Transition?, after clipID: UUID) throws {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        guard index + 1 < clips.count else { return }
        clips[index].transitionOut = transition
    }

    // MARK: Ripple delete of timeline ranges (silence removal)

    /// Removes the given timeline ranges from the main track and closes the gaps.
    /// Text overlays and captions after each cut shift left with the video.
    mutating func rippleDelete(ranges: [MediaTimeRange]) {
        // Transitions make timeline↔source mapping ambiguous inside overlaps; drop them first.
        for i in clips.indices { clips[i].transitionOut = nil }
        let merged = Self.merge(ranges).filter { !$0.isEmpty }
        // Work from the end so earlier ranges keep their positions.
        for range in merged.reversed() {
            let total = layout.duration
            guard let cut = range.intersection(MediaTimeRange(start: .zero, duration: total)) else { continue }
            // Split at the edges (ignore splits that would be too short – those slivers are deleted below).
            _ = try? split(at: cut.end)
            _ = try? split(at: cut.start)
            let entries = layout.entries
            let doomed = entries.filter { entry in
                guard let overlap = entry.range.intersection(cut) else { return false }
                // Delete clips that are (almost) entirely inside the cut.
                return entry.range.duration - overlap.duration < Self.minimumClipDuration
            }.map(\.clipID)
            clips.removeAll { doomed.contains($0.id) }
            shiftOverlays(removing: cut)
        }
    }

    private mutating func shiftOverlays(removing cut: MediaTimeRange) {
        func shifted(_ t: MediaTime) -> MediaTime {
            if t >= cut.end { return t - cut.duration }
            if t > cut.start { return cut.start }
            return t
        }
        for i in textOverlays.indices {
            let r = textOverlays[i].range
            textOverlays[i].range = MediaTimeRange(start: shifted(r.start), end: shifted(r.end))
        }
        textOverlays.removeAll { $0.range.duration < Self.minimumClipDuration }
        for s in captions.segments.indices {
            captions.segments[s].words = captions.segments[s].words.compactMap { word in
                let r = MediaTimeRange(start: shifted(word.range.start), end: shifted(word.range.end))
                return r.isEmpty ? nil : CaptionWord(text: word.text, range: r)
            }
        }
        captions.segments.removeAll { $0.words.isEmpty }
        for i in audioClips.indices where audioClips[i].role == .voiceover || audioClips[i].role == .extracted {
            audioClips[i].start = shifted(audioClips[i].start)
        }
    }

    static func merge(_ ranges: [MediaTimeRange]) -> [MediaTimeRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var result: [MediaTimeRange] = []
        for r in sorted {
            if let last = result.last, r.start <= last.end {
                result[result.count - 1] = MediaTimeRange(start: last.start, end: max(last.end, r.end))
            } else {
                result.append(r)
            }
        }
        return result
    }

    // MARK: Beat sync

    /// Re-times main-track cuts so each one lands on a beat.
    ///
    /// Clips are walked in order; each clip's end is moved to the beat nearest
    /// to its current end (shortening, or lengthening when the source allows).
    /// Returns the number of cuts that were aligned.
    @discardableResult
    mutating func syncCutsToBeats(_ beats: [MediaTime], minimumClip: MediaTime = MediaTime(seconds: 0.4)) -> Int {
        let beats = beats.sorted()
        guard !beats.isEmpty, clips.count > 1 else { return 0 }
        for i in clips.indices { clips[i].transitionOut = nil }
        var aligned = 0
        var cursor = MediaTime.zero
        for i in 0..<(clips.count - 1) {
            let clip = clips[i]
            let currentEnd = cursor + clip.timelineDuration
            let maxDuration: MediaTime
            if clip.isStill {
                maxDuration = MediaTime(seconds: 60)
            } else if let item = mediaItem(clip.mediaID) {
                let available = clip.isReversed ? clip.sourceRange.end : item.duration - clip.sourceRange.start
                maxDuration = available.divided(by: clip.speed)
            } else {
                maxDuration = clip.timelineDuration
            }
            let candidates = beats.filter { $0 - cursor >= minimumClip && $0 - cursor <= maxDuration }
            guard let target = candidates.min(by: { abs(($0 - currentEnd).ticks) < abs(($1 - currentEnd).ticks) }) else {
                cursor = currentEnd
                continue
            }
            let newDuration = target - cursor
            if clip.isStill {
                clips[i].sourceRange.duration = newDuration
            } else {
                let sourceDuration = newDuration.multiplied(by: clip.speed)
                if clip.isReversed {
                    clips[i].sourceRange = MediaTimeRange(start: clip.sourceRange.end - sourceDuration,
                                                          end: clip.sourceRange.end)
                } else {
                    clips[i].sourceRange.duration = sourceDuration
                }
            }
            aligned += 1
            cursor = target
        }
        return aligned
    }

    // MARK: Text

    @discardableResult
    mutating func addText(_ text: String, at time: MediaTime, duration: MediaTime = MediaTime(seconds: 3)) -> UUID {
        let overlay = TextOverlay(text: text, range: MediaTimeRange(start: time, duration: duration))
        textOverlays.append(overlay)
        return overlay.id
    }

    mutating func updateText(_ id: UUID, _ change: (inout TextOverlay) -> Void) {
        guard let i = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        change(&textOverlays[i])
    }

    mutating func deleteText(_ id: UUID) {
        textOverlays.removeAll { $0.id == id }
    }

    mutating func updateAudio(_ id: UUID, _ change: (inout AudioClip) -> Void) {
        guard let i = audioClips.firstIndex(where: { $0.id == id }) else { return }
        change(&audioClips[i])
    }

    mutating func deleteAudio(_ id: UUID) {
        audioClips.removeAll { $0.id == id }
    }

    /// Mutes the clip and puts its sound on an audio lane so it can be edited separately.
    @discardableResult
    mutating func extractAudio(from clipID: UUID) throws -> UUID {
        guard let index = clipIndex(clipID) else { throw EditError.clipNotFound }
        let clip = clips[index]
        guard clip.hasAudio, !clip.isReversed, clip.speed == 1,
              let item = mediaItem(clip.mediaID), item.hasAudio else { throw EditError.outOfRange }
        guard let entry = layout.entry(for: clipID) else { throw EditError.clipNotFound }
        var audio = AudioClip(mediaID: clip.mediaID, role: .extracted, sourceRange: clip.sourceRange,
                              start: entry.range.start)
        audio.volume = clip.volume
        audio.name = "Extracted audio"
        clips[index].isMuted = true
        addAudio(audio)
        return audio.id
    }
}
