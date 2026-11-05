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
        // Title cards always fill (their content is kept in a safe centre area).
        for i in clips.indices where clips[i].titleCard == nil {
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
        var overlay = TextOverlay(text: text, range: MediaTimeRange(start: time, duration: duration))
        // New text uses the shared animation set: pop in, fade out.
        var anim = ClipAnimation()
        anim.entrance = .pop
        anim.exit = .fade
        anim.inDuration = 0.4
        anim.outDuration = 0.4
        overlay.animation = anim
        overlay.animationIn = .none
        overlay.animationOut = .none
        textOverlays.append(overlay)
        return overlay.id
    }

    mutating func updateText(_ id: UUID, _ change: (inout TextOverlay) -> Void) {
        guard let i = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        change(&textOverlays[i])
    }

    static let textDurationRange = MediaTime(seconds: 0.5)...MediaTime(seconds: 30)

    mutating func setTextDuration(_ id: UUID, _ duration: MediaTime) {
        updateText(id) { $0.range.duration = duration.clamped(to: Self.textDurationRange) }
    }

    mutating func moveText(_ id: UUID, toStart start: MediaTime) {
        updateText(id) { $0.range.start = max(.zero, start) }
    }

    /// Fixed position; nil returns the text to free (dragged) placement.
    mutating func setTextAnchor(_ id: UUID, _ anchor: OverlayAnchor?) {
        updateText(id) { t in
            t.anchor = anchor
            if anchor == nil { t.centerX = 0.5; t.centerY = 0.5 }
        }
    }

    @discardableResult
    mutating func duplicateText(_ id: UUID) -> UUID? {
        guard let t = textOverlays.first(where: { $0.id == id }) else { return nil }
        var copy = t
        copy.id = UUID()
        copy.range.start = t.range.end
        textOverlays.append(copy)
        return copy.id
    }

    /// Opening / closing slide clip, if present.
    func titleCardClip(_ placement: TitleCard.Placement) -> VideoClip? {
        clips.first { $0.titleCard?.placement == placement }
    }

    /// Adds or replaces the opening (first) / closing (last) slide with a rendered image.
    mutating func upsertTitleCard(_ card: TitleCard, image: MediaItem, duration: MediaTime) {
        if !media.contains(where: { $0.id == image.id }) { media.append(image) }
        if let i = clips.firstIndex(where: { $0.titleCard?.placement == card.placement }) {
            clips[i].mediaID = image.id
            clips[i].titleCard = card
            clips[i].sourceRange.duration = duration.clamped(to: Self.stillDurationRange)
            return
        }
        var clip = VideoClip(mediaID: image.id, kind: .photo,
                             sourceRange: MediaTimeRange(start: .zero, duration: duration.clamped(to: Self.stillDurationRange)))
        clip.titleCard = card
        clip.transform.fit = .fill      // square card, safe centre: fills any canvas ratio
        if card.placement == .opening { clips.insert(clip, at: 0) } else { clips.append(clip) }
    }

    mutating func removeTitleCard(_ placement: TitleCard.Placement) {
        clips.removeAll { $0.titleCard?.placement == placement }
        if let last = clips.indices.last { clips[last].transitionOut = nil }
    }

    mutating func deleteText(_ id: UUID) {
        textOverlays.removeAll { $0.id == id }
    }

    mutating func updateAudio(_ id: UUID, _ change: (inout AudioClip) -> Void) {
        guard let i = audioClips.firstIndex(where: { $0.id == id }) else { return }
        change(&audioClips[i])
    }

    // MARK: Audio clip editing

    /// Re-fits music that follows the video so it ends with the video (or with the
    /// song, if the song is shorter). Called after every edit.
    mutating func refitMusic() {
        let videoEnd = layout.duration
        guard videoEnd > .zero else { return }
        for i in audioClips.indices where audioClips[i].followsVideo && !audioClips[i].hasSectionEdits {
            guard let item = mediaItem(audioClips[i].mediaID) else { continue }
            let clip = audioClips[i]
            let available = item.duration - clip.sourceRange.start
            let wanted = videoEnd - clip.start
            let length = max(Self.minimumAudioDuration, min(available, wanted))
            if length != clip.sourceRange.duration { audioClips[i].sourceRange.duration = length }
        }
    }

    static let minimumAudioDuration = MediaTime(seconds: 0.2)

    private func audioIndex(_ id: UUID) throws -> (Int, MediaTime) {
        guard let i = audioClips.firstIndex(where: { $0.id == id }),
              let item = mediaItem(audioClips[i].mediaID) else { throw EditError.clipNotFound }
        return (i, item.duration)
    }

    /// Sets which part of the song plays (source start/end), keeping its timeline start.
    mutating func setAudioSourceRange(_ id: UUID, _ range: MediaTimeRange) throws {
        let (i, total) = try audioIndex(id)
        let start = range.start.clamped(to: .zero...max(.zero, total - Self.minimumAudioDuration))
        let end = range.end.clamped(to: (start + Self.minimumAudioDuration)...max(start + Self.minimumAudioDuration, total))
        // A new end chosen by the user means the music no longer follows the video.
        if min(end, total) != audioClips[i].sourceRange.end { audioClips[i].fitsVideo = false }
        audioClips[i].sourceRange = MediaTimeRange(start: start, end: min(end, total))
    }

    /// Slides the section of the song that plays, keeping its length ("use a part from the middle").
    mutating func slideAudioContent(_ id: UUID, toSourceStart start: MediaTime) throws {
        let (i, total) = try audioIndex(id)
        let length = audioClips[i].sourceRange.duration
        let s = start.clamped(to: .zero...max(.zero, total - length))
        audioClips[i].sourceRange = MediaTimeRange(start: s, duration: length)
    }

    /// Moves where the audio starts on the timeline.
    mutating func moveAudio(_ id: UUID, toTimelineStart start: MediaTime) throws {
        let (i, _) = try audioIndex(id)
        audioClips[i].start = max(.zero, start)
    }

    /// Splits an audio clip at a timeline time. Returns the new right-hand clip's id.
    @discardableResult
    mutating func splitAudio(_ id: UUID, at time: MediaTime) throws -> UUID {
        let (i, _) = try audioIndex(id)
        let clip = audioClips[i]
        let local = time - clip.start
        guard local >= Self.minimumAudioDuration, clip.sourceRange.duration - local >= Self.minimumAudioDuration else {
            throw EditError.tooShort
        }
        var left = clip, right = clip
        right.id = UUID()
        left.fitsVideo = false
        right.fitsVideo = false
        left.sourceRange.duration = local
        left.fadeOut = .zero
        right.sourceRange = MediaTimeRange(start: clip.sourceRange.start + local, end: clip.sourceRange.end)
        right.start = time
        right.fadeIn = .zero
        audioClips[i] = left
        audioClips.insert(right, at: i + 1)
        return right.id
    }

    // MARK: Audio markers & sections

    /// Adds a marker at a song (source) time, splitting the section that contains it.
    mutating func addAudioMarker(_ id: UUID, at time: MediaTime) throws {
        let (i, _) = try audioIndex(id)
        var secs = audioClips[i].resolvedSections
        guard let k = secs.firstIndex(where: { time > $0.start + Self.minimumAudioDuration && time < $0.end - Self.minimumAudioDuration })
        else { throw EditError.tooShort }
        let s = secs[k]
        secs[k].end = time
        secs.insert(AudioSection(start: time, end: s.end, volume: s.volume, deleted: s.deleted), at: k + 1)
        audioClips[i].sections = secs
        audioClips[i].fitsVideo = false
    }

    /// Removes the marker after section `index` (merges it with the next section).
    mutating func removeAudioMarker(_ id: UUID, after index: Int) throws {
        let (i, _) = try audioIndex(id)
        var secs = audioClips[i].resolvedSections
        guard index >= 0, index + 1 < secs.count else { throw EditError.outOfRange }
        secs[index].end = secs[index + 1].end
        secs.remove(at: index + 1)
        audioClips[i].sections = secs.count == 1 && secs[0].volume == 1 && !secs[0].deleted ? nil : secs
    }

    mutating func clearAudioMarkers(_ id: UUID) throws {
        let (i, _) = try audioIndex(id)
        audioClips[i].sections = nil
    }

    mutating func setAudioSectionVolume(_ id: UUID, index: Int, _ volume: Double) throws {
        let (i, _) = try audioIndex(id)
        var secs = audioClips[i].resolvedSections
        guard secs.indices.contains(index) else { throw EditError.outOfRange }
        secs[index].volume = min(max(volume, 0), 2)
        audioClips[i].sections = secs
        audioClips[i].fitsVideo = false
    }

    /// Deletes (cuts out) or restores a section. At least one section always remains.
    mutating func setAudioSectionDeleted(_ id: UUID, index: Int, _ deleted: Bool) throws {
        let (i, _) = try audioIndex(id)
        var secs = audioClips[i].resolvedSections
        guard secs.indices.contains(index) else { throw EditError.outOfRange }
        if deleted, secs.filter({ !$0.deleted }).count <= 1 { throw EditError.tooShort }
        secs[index].deleted = deleted
        audioClips[i].sections = secs
        audioClips[i].fitsVideo = false
    }

    /// Repeats an audio clip's section back to back until the end of the video.
    /// The last copy is cut at the video's end and carries the original fade-out.
    /// Returns how many copies were added (0 when it already reaches the end).
    @discardableResult
    mutating func repeatAudio(_ id: UUID) throws -> Int {
        let (i, _) = try audioIndex(id)
        let videoEnd = layout.duration
        var original = audioClips[i]
        let length = original.playedDuration
        guard length >= Self.minimumAudioDuration, original.timelineRange.end < videoEnd - Self.minimumAudioDuration else {
            return 0
        }
        let fadeOut = original.fadeOut
        original.fitsVideo = false
        original.fadeOut = .zero
        audioClips[i] = original
        var cursor = original.timelineRange.end
        var copies: [AudioClip] = []
        while videoEnd - cursor >= Self.minimumAudioDuration {
            var copy = original
            copy.id = UUID()
            copy.start = cursor
            copy.fadeIn = .zero
            // Sectioned clips keep their structure; the composition stops them at the video end.
            if !original.hasSectionEdits { copy.sourceRange.duration = min(length, videoEnd - cursor) }
            copies.append(copy)
            cursor = copy.timelineRange.end
        }
        guard !copies.isEmpty else { return 0 }
        copies[copies.count - 1].fadeOut = fadeOut
        for copy in copies {
            let collides = audioClips.contains { $0.lane == copy.lane && $0.timelineRange.intersection(copy.timelineRange) != nil }
            if collides { addAudio(copy) } else { audioClips.append(copy) }
        }
        return copies.count
    }

    /// Copies an audio clip and places it right after the original (same lane when free).
    @discardableResult
    mutating func duplicateAudio(_ id: UUID) throws -> UUID {
        let (i, _) = try audioIndex(id)
        var copy = audioClips[i]
        copy.id = UUID()
        copy.fitsVideo = false
        audioClips[i].fitsVideo = false
        copy.start = audioClips[i].timelineRange.end
        let collides = audioClips.contains { $0.lane == copy.lane && $0.timelineRange.intersection(copy.timelineRange) != nil }
        if collides {
            addAudio(copy)
        } else {
            audioClips.insert(copy, at: i + 1)
        }
        return copy.id
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
