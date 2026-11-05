import Testing
import Foundation
@testable import EditorKit

private func s(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

/// Builds a project with videos of the given lengths (seconds) on the main track.
private func makeProject(_ lengths: [Double]) -> Project {
    var p = Project(name: "Test")
    for (i, len) in lengths.enumerated() {
        let item = MediaItem(kind: .video, fileName: "v\(i).mov", naturalSize: CGSize(width: 1920, height: 1080),
                             duration: s(len), hasAudio: true)
        p.appendClip(for: item)
    }
    return p
}

@Suite("MediaTime")
struct MediaTimeTests {
    @Test func secondsRoundTrip() {
        #expect(s(1.5).ticks == 90_000)
        #expect(s(1.5).seconds == 1.5)
        #expect(MediaTime(s(2.25).cmTime) == s(2.25))
    }

    @Test func frameSnapping() {
        #expect(s(1.01).snappedToFrame(fps: 30) == s(1.0))
        #expect(s(1.02).snappedToFrame(fps: 30) == MediaTime(ticks: 62_000))
    }

    @Test func timecodeFormatting() {
        #expect(s(75.25).timecode == "1:15.2" || s(75.25).timecode == "1:15.3")
        #expect(s(0).timecode == "0:00.0")
    }

    @Test func codableIsCompactInteger() throws {
        let data = try JSONEncoder().encode(s(2))
        #expect(String(decoding: data, as: UTF8.self) == "120000")
    }
}

@Suite("Timeline layout")
struct LayoutTests {
    @Test func clipsAreBackToBack() {
        let p = makeProject([2, 3, 4])
        let layout = p.layout
        #expect(layout.duration == s(9))
        #expect(layout.entries.map(\.range.start) == [s(0), s(2), s(5)])
        #expect(layout.cutTimes == [s(2), s(5)])
    }

    @Test func transitionsOverlapClips() throws {
        var p = makeProject([2, 3])
        try p.setTransition(Transition(kind: .dissolve, duration: s(0.5)), after: p.clips[0].id)
        #expect(p.layout.duration == s(4.5))
        #expect(p.layout.entries[1].range.start == s(1.5))
    }

    @Test func transitionIsClampedToHalfTheShortestClip() throws {
        var p = makeProject([1, 3])
        try p.setTransition(Transition(kind: .fade, duration: s(2)), after: p.clips[0].id)
        #expect(p.layout.entries[0].overlapOut == s(0.5))
    }

    @Test func speedChangesDuration() throws {
        var p = makeProject([4])
        try p.setSpeed(2, clipID: p.clips[0].id)
        #expect(p.layout.duration == s(2))
        try p.setSpeed(0.5, clipID: p.clips[0].id)
        #expect(p.layout.duration == s(8))
        try p.setSpeed(100, clipID: p.clips[0].id)
        #expect(p.clips[0].speed == 10)
    }
}

@Suite("Split")
struct SplitTests {
    @Test func splitsClipAtPlayhead() throws {
        var p = makeProject([4])
        let newID = try p.split(at: s(1.5))
        #expect(p.clips.count == 2)
        #expect(p.clips[0].sourceRange == MediaTimeRange(start: s(0), end: s(1.5)))
        #expect(p.clips[1].sourceRange == MediaTimeRange(start: s(1.5), end: s(4)))
        #expect(p.clips[1].id == newID)
        #expect(p.layout.duration == s(4))
    }

    @Test func splitRespectsSpeed() throws {
        var p = makeProject([4])
        try p.setSpeed(2, clipID: p.clips[0].id)
        try p.split(at: s(0.5)) // 0.5 s on the timeline = 1 s of source
        #expect(p.clips[0].sourceRange.duration == s(1))
        #expect(p.clips[1].sourceRange.start == s(1))
        #expect(p.layout.duration == s(2))
    }

    @Test func splitReversedClip() throws {
        var p = makeProject([4])
        try p.setReversed(true, clipID: p.clips[0].id)
        try p.split(at: s(1))
        // First second of a reversed clip shows source 3...4.
        #expect(p.clips[0].sourceRange == MediaTimeRange(start: s(3), end: s(4)))
        #expect(p.clips[1].sourceRange == MediaTimeRange(start: s(0), end: s(3)))
    }

    @Test func splitInSecondClip() throws {
        var p = makeProject([2, 3])
        try p.split(at: s(3))
        #expect(p.clips.count == 3)
        #expect(p.clips[1].sourceRange == MediaTimeRange(start: s(0), end: s(1)))
        #expect(p.clips[2].sourceRange == MediaTimeRange(start: s(1), end: s(3)))
    }

    @Test func refusesTinySplits() {
        var p = makeProject([4])
        #expect(throws: EditError.tooShort) { try p.split(at: s(0.05)) }
        #expect(throws: EditError.outOfRange) { try p.split(at: s(10)) }
    }

    @Test func splitMovesTransitionToRightHalf() throws {
        var p = makeProject([4, 4])
        try p.setTransition(Transition(kind: .fade), after: p.clips[0].id)
        try p.split(at: s(1))
        #expect(p.clips[0].transitionOut == nil)
        #expect(p.clips[1].transitionOut?.kind == .fade)
    }
}

@Suite("Trim")
struct TrimTests {
    @Test func trimLeadingAndTrailing() throws {
        var p = makeProject([10])
        let id = p.clips[0].id
        try p.trim(clipID: id, edge: .leading, by: s(2))
        try p.trim(clipID: id, edge: .trailing, by: s(-3))
        #expect(p.clips[0].sourceRange == MediaTimeRange(start: s(2), end: s(7)))
    }

    @Test func trimIsClampedToSource() throws {
        var p = makeProject([10])
        let id = p.clips[0].id
        try p.trim(clipID: id, edge: .leading, by: s(-5))
        try p.trim(clipID: id, edge: .trailing, by: s(5))
        #expect(p.clips[0].sourceRange == MediaTimeRange(start: s(0), end: s(10)))
        try p.trim(clipID: id, edge: .leading, by: s(20))
        #expect(p.clips[0].sourceRange.duration == Project.minimumClipDuration)
    }

    @Test func trimReversedLeadingEdgeRemovesSourceEnd() throws {
        var p = makeProject([10])
        let id = p.clips[0].id
        try p.setReversed(true, clipID: id)
        try p.trim(clipID: id, edge: .leading, by: s(2))
        #expect(p.clips[0].sourceRange == MediaTimeRange(start: s(0), end: s(8)))
    }

    @Test func photosCanBeLengthened() throws {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 100, height: 100),
                                    duration: .zero, hasAudio: false))
        try p.trim(clipID: p.clips[0].id, edge: .trailing, by: s(2))
        #expect(p.layout.duration == s(5))
    }
}

@Suite("Arrange")
struct ArrangeTests {
    @Test func deleteDuplicateMove() throws {
        var p = makeProject([1, 2, 3])
        let ids = p.clips.map(\.id)
        try p.deleteClip(ids[1])
        #expect(p.clips.map(\.id) == [ids[0], ids[2]])
        let copy = try p.duplicateClip(ids[0])
        #expect(p.clips.map(\.id) == [ids[0], copy, ids[2]])
        try p.moveClip(ids[2], to: 0)
        #expect(p.clips.map(\.id) == [ids[2], ids[0], copy])
        #expect(p.layout.duration == s(5))
    }

    @Test func freezeFrameInsertsStill() throws {
        var p = makeProject([4])
        let freeze = try p.insertFreezeFrame(at: s(2))
        #expect(p.clips.count == 3)
        #expect(p.clips[1].id == freeze)
        #expect(p.clips[1].freezeAt == s(2))
        #expect(p.layout.duration == s(5.5))
    }

    @Test func extractAudioMutesClipAndAddsLane() throws {
        var p = makeProject([2, 3])
        let audioID = try p.extractAudio(from: p.clips[1].id)
        #expect(p.clips[1].isMuted)
        let audio = try #require(p.audioClips.first { $0.id == audioID })
        #expect(audio.start == s(2))
        #expect(audio.sourceRange.duration == s(3))
    }
}

@Suite("Ripple delete (silence removal)")
struct RippleDeleteTests {
    @Test func removesRangesAndClosesGaps() {
        var p = makeProject([10])
        p.rippleDelete(ranges: [MediaTimeRange(start: s(2), end: s(3)),
                                MediaTimeRange(start: s(6), end: s(8))])
        #expect(p.layout.duration == s(7))
        #expect(p.clips.map(\.sourceRange) == [
            MediaTimeRange(start: s(0), end: s(2)),
            MediaTimeRange(start: s(3), end: s(6)),
            MediaTimeRange(start: s(8), end: s(10)),
        ])
    }

    @Test func removesAcrossClipBoundaries() {
        var p = makeProject([3, 3])
        p.rippleDelete(ranges: [MediaTimeRange(start: s(2), end: s(4))])
        #expect(p.layout.duration == s(4))
        #expect(p.clips.count == 2)
        #expect(p.clips[0].sourceRange.end == s(2))
        #expect(p.clips[1].sourceRange.start == s(1))
    }

    @Test func mergesOverlappingRanges() {
        let merged = Project.merge([MediaTimeRange(start: s(1), end: s(3)),
                                    MediaTimeRange(start: s(2), end: s(4)),
                                    MediaTimeRange(start: s(6), end: s(7))])
        #expect(merged == [MediaTimeRange(start: s(1), end: s(4)), MediaTimeRange(start: s(6), end: s(7))])
    }

    @Test func shiftsTextAndCaptions() {
        var p = makeProject([10])
        p.addText("Hello", at: s(5), duration: s(2))
        p.captions.segments = [CaptionSegment(words: [
            CaptionWord(text: "gone", range: MediaTimeRange(start: s(1.2), end: s(1.6))),
            CaptionWord(text: "kept", range: MediaTimeRange(start: s(4), end: s(4.5))),
        ])]
        p.rippleDelete(ranges: [MediaTimeRange(start: s(1), end: s(2))])
        #expect(p.textOverlays[0].range.start == s(4))
        #expect(p.captions.segments[0].words.map(\.text) == ["kept"])
        #expect(p.captions.segments[0].words[0].range.start == s(3))
    }
}

@Suite("Beat sync")
struct BeatSyncTests {
    @Test func cutsLandOnBeats() {
        var p = makeProject([2.3, 1.8, 3])
        let beats = stride(from: 0.0, to: 10, by: 0.5).map { s($0) }
        let aligned = p.syncCutsToBeats(beats)
        #expect(aligned == 2)
        for cut in p.layout.cutTimes {
            #expect(cut.ticks % s(0.5).ticks == 0, "cut \(cut) is not on a beat")
        }
    }

    @Test func doesNotExceedSourceLength() {
        var p = makeProject([2.3, 2])
        p.syncCutsToBeats([s(3)]) // only beat is beyond the first clip's media
        #expect(p.clips[0].sourceRange.duration == s(2.3))
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func saveLoadRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        var p = try store.create(name: "Trip")
        p.appendClip(for: MediaItem(kind: .video, fileName: "a.mov", naturalSize: CGSize(width: 10, height: 10),
                                    duration: s(5), hasAudio: true))
        p.addText("Title", at: .zero)
        p.background = .color(.white)
        try store.save(p)
        let loaded = try store.load(p.id)
        #expect(loaded == p)
        #expect(store.listProjects().map(\.id) == [p.id])
        let copy = try store.duplicate(p.id)
        #expect(copy.name == "Trip Copy")
        #expect(store.listProjects().count == 2)
        try store.delete(p.id)
        #expect(store.listProjects().map(\.id) == [copy.id])
    }
}

@Suite("Undo / redo")
@MainActor
struct UndoTests {
    @Test func undoRedoRestoresSnapshots() throws {
        let session = EditSession(project: makeProject([4]))
        try session.apply("Split") { try $0.split(at: s(2)) }
        #expect(session.project.clips.count == 2)
        #expect(session.undoLabel == "Split")
        session.undo()
        #expect(session.project.clips.count == 1)
        session.redo()
        #expect(session.project.clips.count == 2)
    }

    @Test func failedEditLeavesNoHistory() {
        let session = EditSession(project: makeProject([4]))
        #expect(throws: EditError.self) { try session.apply("Split") { try $0.split(at: s(99)) } }
        #expect(!session.canUndo)
    }

    @Test func coalescedSliderChangesAreOneStep() throws {
        let session = EditSession(project: makeProject([4]))
        let id = session.project.clips[0].id
        for v in stride(from: 0.1, through: 1.0, by: 0.1) {
            session.applyCoalescing("Exposure", key: "exp-\(id)") { p in
                try? p.updateClip(id) { $0.adjustments.exposure = v }
            }
        }
        #expect(session.undoStack.count == 1)
        session.undo()
        #expect(session.project.clips[0].adjustments.exposure == 0)
    }

    @Test func selectionClearsWhenClipDisappears() throws {
        let session = EditSession(project: makeProject([4, 2]))
        let id = session.project.clips[1].id
        session.selection = .clip(id)
        try session.apply("Delete") { try $0.deleteClip(id) }
        #expect(session.selection == .none)
    }
}

@Suite("Canvas")
struct CanvasTests {
    @Test func renderSizes() {
        #expect(AspectRatio.portrait3x4.renderSize(shortEdge: 1080) == CGSize(width: 1080, height: 1440))
        #expect(AspectRatio.portrait9x16.renderSize(shortEdge: 1080) == CGSize(width: 1080, height: 1920))
        #expect(AspectRatio.landscape16x9.renderSize(shortEdge: 720) == CGSize(width: 1280, height: 720))
        #expect(AspectRatio.allCases.map(\.rawValue) == ["9:16", "3:4", "1:1", "4:5", "16:9"])
    }
}

@Suite("Photo duration")
struct PhotoDurationTests {
    @Test func clampsAndAppliesToAllPhotos() throws {
        var p = Project(name: "P")
        let size = CGSize(width: 10, height: 10)
        p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: size, duration: .zero, hasAudio: false))
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: size, duration: s(4), hasAudio: false))
        p.appendClip(for: MediaItem(kind: .photo, fileName: "b.jpg", naturalSize: size, duration: .zero, hasAudio: false))
        try p.setStillDuration(s(100), clipID: p.clips[0].id)
        #expect(p.clips[0].timelineDuration == s(30))
        try p.setStillDuration(s(0.1), clipID: p.clips[0].id)
        #expect(p.clips[0].timelineDuration == s(0.5))
        try p.setStillDuration(s(5), clipID: p.clips[1].id)
        #expect(p.clips[1].timelineDuration == s(4), "videos are untouched")
        try p.setStillDuration(s(2), clipID: p.clips[2].id, allPhotos: true)
        #expect(p.clips[0].timelineDuration == s(2) && p.clips[2].timelineDuration == s(2))
        #expect(p.layout.duration == s(8))
    }
}

@Suite("Audio editing")
struct AudioEditingTests {
    /// 10 s of video plus a 30 s song on the timeline.
    private func project() -> (Project, UUID) {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(10), hasAudio: false))
        let song = MediaItem(kind: .audio, fileName: "song.m4a", naturalSize: .zero, duration: s(30), hasAudio: true)
        p.media.append(song)
        var clip = AudioClip(mediaID: song.id, role: .music, sourceRange: MediaTimeRange(start: .zero, duration: s(10)), start: .zero)
        clip.beats = stride(from: 0.0, to: 30, by: 0.5).map { s($0) }
        p.addAudio(clip)
        return (p, clip.id)
    }

    @Test func trimStartAndEndWithinSong() throws {
        var (p, id) = project()
        try p.setAudioSourceRange(id, MediaTimeRange(start: s(2), end: s(8)))
        #expect(p.audioClips[0].sourceRange == MediaTimeRange(start: s(2), end: s(8)))
        try p.setAudioSourceRange(id, MediaTimeRange(start: s(-5), end: s(99)))
        #expect(p.audioClips[0].sourceRange == MediaTimeRange(start: s(0), end: s(30)), "clamped to the song")
    }

    @Test func slideSectionKeepsLength() throws {
        var (p, id) = project()
        try p.slideAudioContent(id, toSourceStart: s(12))
        #expect(p.audioClips[0].sourceRange == MediaTimeRange(start: s(12), end: s(22)))
        try p.slideAudioContent(id, toSourceStart: s(28))
        #expect(p.audioClips[0].sourceRange == MediaTimeRange(start: s(20), end: s(30)), "can't run past the song end")
        // Beats follow the section: the first timeline beat is still on the grid.
        #expect(p.audioClips[0].timelineBeats.first == s(0))
    }

    @Test func moveSplitDuplicate() throws {
        var (p, id) = project()
        try p.moveAudio(id, toTimelineStart: s(1))
        #expect(p.audioClips[0].start == s(1))
        let right = try p.splitAudio(id, at: s(4))
        #expect(p.audioClips.count == 2)
        #expect(p.audioClips[0].sourceRange == MediaTimeRange(start: s(0), end: s(3)))
        let r = try #require(p.audioClips.first { $0.id == right })
        #expect(r.start == s(4) && r.sourceRange == MediaTimeRange(start: s(3), end: s(10)))
        #expect(throws: EditError.tooShort) { try p.splitAudio(id, at: s(1.05)) }
        let copy = try p.duplicateAudio(right)
        let c = try #require(p.audioClips.first { $0.id == copy })
        #expect(c.start == r.timelineRange.end && c.sourceRange == r.sourceRange && c.lane == r.lane)
    }
}

@Suite("Empty projects")
struct EmptyProjectTests {
    @Test func emptyUntilSomethingIsAdded() {
        var p = Project(name: "P")
        #expect(p.isEmptyEdit)
        p.addText("Hi", at: .zero)
        #expect(!p.isEmptyEdit)
    }
}

@Suite("Music follows video length")
struct MusicFollowsVideoTests {
    private func project(video: Double, song: Double) -> Project {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(video), hasAudio: false))
        let item = MediaItem(kind: .audio, fileName: "song.m4a", naturalSize: .zero, duration: s(song), hasAudio: true)
        p.media.append(item)
        var clip = AudioClip(mediaID: item.id, role: .music, sourceRange: MediaTimeRange(start: .zero, duration: s(video)), start: .zero)
        clip.fitsVideo = true
        p.addAudio(clip)
        return p
    }

    @Test func growsAndShrinksWithTheVideo() {
        var p = project(video: 90, song: 180)
        p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false), photoDuration: s(15))
        p.refitMusic()
        #expect(p.audioClips[0].sourceRange.duration == s(105), "music extends to the new 105 s end")
        p.clips.removeLast()
        p.refitMusic()
        #expect(p.audioClips[0].sourceRange.duration == s(90))
    }

    @Test func stopsAtTheEndOfAShortSong() {
        var p = project(video: 90, song: 100)
        p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false), photoDuration: s(30))
        p.refitMusic()
        #expect(p.audioClips[0].sourceRange.duration == s(100))
    }

    @Test func manualEndStopsFollowing() throws {
        var p = project(video: 90, song: 180)
        let id = p.audioClips[0].id
        try p.setAudioSourceRange(id, MediaTimeRange(start: .zero, end: s(60)))
        p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false), photoDuration: s(15))
        p.refitMusic()
        #expect(p.audioClips[0].sourceRange.duration == s(60), "user-chosen end is kept")
    }

    @Test @MainActor func everyEditRefits() throws {
        let session = EditSession(project: project(video: 90, song: 180))
        try session.apply("Add photo") { p in
            p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false), photoDuration: s(10))
        }
        #expect(session.project.audioClips[0].sourceRange.duration == s(100))
        session.undo()
        #expect(session.project.audioClips[0].sourceRange.duration == s(90))
    }
}

@Suite("Repeat audio")
struct RepeatAudioTests {
    @Test func fillsToTheVideoEnd() throws {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(25), hasAudio: false))
        let song = MediaItem(kind: .audio, fileName: "s.m4a", naturalSize: .zero, duration: s(60), hasAudio: true)
        p.media.append(song)
        var clip = AudioClip(mediaID: song.id, role: .music, sourceRange: MediaTimeRange(start: s(5), duration: s(8)), start: .zero)
        clip.fadeOut = s(1.5)
        clip.fitsVideo = false
        p.addAudio(clip)
        let added = try p.repeatAudio(clip.id)
        // 0–8, 8–16, 16–24, 24–25 (last cut at the end).
        #expect(added == 3)
        let sorted = p.audioClips.sorted { $0.start < $1.start }
        #expect(sorted.map(\.start) == [s(0), s(8), s(16), s(24)])
        #expect(sorted.last?.sourceRange == MediaTimeRange(start: s(5), duration: s(1)))
        #expect(sorted.allSatisfy { $0.sourceRange.start == s(5) && $0.lane == 0 })
        #expect(sorted.dropLast().allSatisfy { $0.fadeOut == .zero } && sorted.last?.fadeOut == s(1.5))
        #expect(try p.repeatAudio(clip.id) == 0, "already reaches the end")
    }
}
