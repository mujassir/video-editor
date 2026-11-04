import Foundation

/// Resolved timeline positions for the main track.
///
/// Clips are laid out back to back. A transition between clip `i` and `i + 1`
/// overlaps the two clips by its duration (clamped so it never exceeds half of
/// either clip), which shortens the total timeline.
public struct TimelineLayout: Sendable {
    public struct Entry: Sendable, Hashable {
        public var clipID: UUID
        public var index: Int
        /// Range the clip occupies on the timeline (includes transition overlaps).
        public var range: MediaTimeRange
        /// Overlap with the next clip (transition duration actually used).
        public var overlapOut: MediaTime
        /// Overlap with the previous clip.
        public var overlapIn: MediaTime
    }

    public var entries: [Entry]
    public var duration: MediaTime

    public init(clips: [VideoClip]) {
        var entries: [Entry] = []
        entries.reserveCapacity(clips.count)
        var cursor = MediaTime.zero
        var previousOverlap = MediaTime.zero
        for (i, clip) in clips.enumerated() {
            let duration = clip.timelineDuration
            var overlap = MediaTime.zero
            if i + 1 < clips.count, let transition = clip.transitionOut {
                let nextDuration = clips[i + 1].timelineDuration
                let limit = MediaTime(ticks: min(duration.ticks, nextDuration.ticks) / 2)
                overlap = min(transition.duration, limit)
            }
            entries.append(Entry(clipID: clip.id, index: i,
                                 range: MediaTimeRange(start: cursor, duration: duration),
                                 overlapOut: overlap, overlapIn: previousOverlap))
            cursor = cursor + duration - overlap
            previousOverlap = overlap
        }
        self.entries = entries
        self.duration = entries.last.map { $0.range.end } ?? .zero
    }

    public func entry(for clipID: UUID) -> Entry? { entries.first { $0.clipID == clipID } }

    /// The clip whose range contains `time`. During a transition the incoming clip wins.
    public func entry(at time: MediaTime) -> Entry? {
        if let last = entries.last(where: { $0.range.contains(time) }) { return last }
        if let last = entries.last, time >= last.range.end, time == duration { return last }
        return nil
    }

    /// Timeline positions of every cut (start of each clip after the first).
    public var cutTimes: [MediaTime] { entries.dropFirst().map(\.range.start) }
}

public extension Project {
    var layout: TimelineLayout { TimelineLayout(clips: clips) }

    /// Nothing has been added yet (no clips, audio, text or captions).
    var isEmptyEdit: Bool {
        clips.isEmpty && audioClips.isEmpty && textOverlays.isEmpty && captions.segments.isEmpty
    }

    /// Total length of the edit, including free audio and text that extend past the video.
    var duration: MediaTime {
        var d = layout.duration
        for a in audioClips where a.role == .voiceover { d = max(d, a.timelineRange.end) }
        return d
    }
}
