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

@Suite("Music shows the whole song")
struct MusicFullLengthTests {
    private func project(video: Double, song: Double, stored: Double? = nil) -> Project {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(video), hasAudio: false))
        let item = MediaItem(kind: .audio, fileName: "song.m4a", naturalSize: .zero, duration: s(song), hasAudio: true)
        p.media.append(item)
        var clip = AudioClip(mediaID: item.id, role: .music, sourceRange: MediaTimeRange(start: .zero, duration: s(stored ?? song)), start: .zero)
        clip.fitsVideo = true
        p.addAudio(clip)
        return p
    }

    @Test func longSongKeepsItsFullLengthOnTheTimeline() {
        var p = project(video: 60, song: 180)
        p.refitMusic()
        #expect(p.audioClips[0].sourceRange.duration == s(180))
        #expect(p.timelineDuration == s(180), "timeline shows the whole song")
        #expect(p.duration == s(60), "preview and export stop at the end of the video")
    }

    @Test func olderProjectsTrimmedToTheVideoGetTheWholeSongBack() {
        var p = project(video: 60, song: 180, stored: 60)
        p.refitMusic()
        #expect(p.audioClips[0].sourceRange.duration == s(180))
    }

    @Test func cutPiecesAreSeparateClips() throws {
        var p = project(video: 60, song: 180)
        let id = p.audioClips[0].id
        let right = try p.splitAudio(id, at: s(40))
        p.refitMusic()
        #expect(p.audioClips.count == 2)
        #expect(p.audioClips[0].sourceRange == MediaTimeRange(start: .zero, end: s(40)))
        let piece = try #require(p.audioClips.first { $0.id == right })
        #expect(piece.start == s(40))
        #expect(piece.sourceRange == MediaTimeRange(start: s(40), end: s(180)))
        // Cuts can be made past the end of the video too.
        _ = try p.splitAudio(right, at: s(120))
        #expect(p.audioClips.count == 3)
    }

    @Test func cuttingSectionedMusicMapsPlayedTimeToTheSong() throws {
        var p = project(video: 60, song: 30)
        let id = p.audioClips[0].id
        try p.addAudioMarker(id, at: s(10))
        try p.addAudioMarker(id, at: s(20))
        try p.setAudioSectionDeleted(id, index: 1, true)   // plays 0–10, then 20–30
        let right = try p.splitAudio(id, at: s(15))          // 5 s into the 20–30 part
        #expect(p.audioClips[0].sourceRange.end == s(25))
        #expect(p.audioClips[0].playedDuration == s(15))
        let piece = try #require(p.audioClips.first { $0.id == right })
        #expect(piece.sourceRange == MediaTimeRange(start: s(25), end: s(30)))
        #expect(piece.playedDuration == s(5))
    }

    @Test @MainActor func editsDoNotTrimMusicToTheVideo() throws {
        let session = EditSession(project: project(video: 60, song: 180))
        try session.apply("Add photo") { p in
            p.appendClip(for: MediaItem(kind: .photo, fileName: "a.jpg", naturalSize: CGSize(width: 10, height: 10), duration: .zero, hasAudio: false), photoDuration: s(10))
        }
        #expect(session.project.audioClips[0].sourceRange.duration == s(180))
        #expect(session.project.duration == s(70))
    }
}

@Suite("Move audio to start")
struct MoveAudioToStartTests {
    @Test func closesTheGapBeforeTheClip() throws {
        var p = Project(name: "P")
        let song = MediaItem(kind: .audio, fileName: "s.m4a", naturalSize: .zero, duration: s(60), hasAudio: true)
        p.media.append(song)
        let first = AudioClip(mediaID: song.id, role: .music, sourceRange: MediaTimeRange(start: .zero, duration: s(5)), start: .zero)
        let late = AudioClip(mediaID: song.id, role: .music, sourceRange: MediaTimeRange(start: .zero, duration: s(5)), start: s(20))
        p.addAudio(first)
        p.addAudio(late)
        // Nothing before the first clip; the late one can move back to where the first ends.
        #expect(p.audioGapStart(first.id) == nil)
        #expect(p.audioGapStart(late.id) == s(5))
        #expect(try p.moveAudioToGapStart(late.id))
        #expect(p.audioClips.first { $0.id == late.id }?.start == s(5))
        #expect(p.audioGapStart(late.id) == nil)
        #expect(try p.moveAudioToGapStart(late.id) == false)
        // With the first clip gone, the blank runs from 0:00.
        p.deleteAudio(first.id)
        #expect(p.audioGapStart(late.id) == .zero)
        try p.moveAudioToGapStart(late.id)
        #expect(p.audioClips.first { $0.id == late.id }?.start == .zero)
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

@Suite("Audio markers & sections")
struct AudioSectionTests {
    private func project() -> (Project, UUID) {
        var p = Project(name: "P")
        p.appendClip(for: MediaItem(kind: .video, fileName: "v.mov", naturalSize: CGSize(width: 10, height: 10), duration: s(30), hasAudio: false))
        let song = MediaItem(kind: .audio, fileName: "s.m4a", naturalSize: .zero, duration: s(60), hasAudio: true)
        p.media.append(song)
        var clip = AudioClip(mediaID: song.id, role: .music, sourceRange: MediaTimeRange(start: .zero, duration: s(30)), start: .zero)
        clip.fitsVideo = true
        p.addAudio(clip)
        return (p, clip.id)
    }

    @Test func markersSplitIntoSections() throws {
        var (p, id) = project()
        try p.addAudioMarker(id, at: s(10))
        try p.addAudioMarker(id, at: s(20))
        let secs = p.audioClips[0].resolvedSections
        #expect(secs.map(\.start) == [s(0), s(10), s(20)] && secs.map(\.end) == [s(10), s(20), s(30)])
        #expect(!p.audioClips[0].followsVideo, "sectioned music keeps its own length")
        #expect(throws: EditError.tooShort) { try p.addAudioMarker(id, at: s(10.05)) }
        try p.removeAudioMarker(id, after: 0)
        #expect(p.audioClips[0].resolvedSections.count == 2)
        try p.clearAudioMarkers(id)
        #expect(p.audioClips[0].sections == nil)
    }

    @Test func deleteAndVolumePerSection() throws {
        var (p, id) = project()
        try p.addAudioMarker(id, at: s(10))
        try p.addAudioMarker(id, at: s(20))
        try p.setAudioSectionDeleted(id, index: 1, true)
        #expect(p.audioClips[0].playedDuration == s(20), "the deleted 10 s is cut out")
        #expect(p.audioClips[0].timelineRange.duration == s(20))
        try p.setAudioSectionVolume(id, index: 2, 0.4)
        #expect(p.audioClips[0].resolvedSections[2].volume == 0.4)
        try p.setAudioSectionDeleted(id, index: 0, true)
        #expect(throws: EditError.tooShort) { try p.setAudioSectionDeleted(id, index: 2, true) }
        try p.setAudioSectionDeleted(id, index: 1, false)
        #expect(p.audioClips[0].playedDuration == s(20))
    }

    @Test func trimClipsSections() throws {
        var (p, id) = project()
        try p.addAudioMarker(id, at: s(10))
        try p.setAudioSourceRange(id, MediaTimeRange(start: s(5), end: s(25)))
        #expect(p.audioClips[0].resolvedSections.map(\.start) == [s(5), s(10)])
        #expect(p.audioClips[0].playedDuration == s(20))
    }
}


@Suite("Caption styles")
struct CaptionPresetTests {
    @Test func onlyClassicKaraokeAndBold() {
        #expect(CaptionPreset.allCases == [.classic, .karaoke, .bold])
    }

    @Test func removedStylesOpenAsTheClosestOneLeft() throws {
        func decode(_ raw: String) throws -> CaptionPreset {
            try JSONDecoder().decode(CaptionPreset.self, from: Data("\"\(raw)\"".utf8))
        }
        #expect(try decode("minimal") == .classic)
        #expect(try decode("neon") == .karaoke)
        #expect(try decode("bold") == .bold)
    }
}


@Suite("Remove caption fillers")
struct CaptionFillerTests {
    private func segment(_ text: String, at start: Double) -> CaptionSegment {
        CaptionSegment(words: text.split(separator: " ").enumerated().map { i, w in
            CaptionWord(text: String(w), range: MediaTimeRange(start: s(start + Double(i) * 0.5), duration: s(0.5)))
        })
    }

    @Test func removesFillersAndKeepsTiming() {
        var track = CaptionTrack()
        track.segments = [segment("Um, so we went uh home", at: 0),
                          segment("Thanks for watching, ah", at: 5),
                          segment("Umm...", at: 9),
                          segment("Uh-huh, the umbrella is here", at: 10)]
        let removed = track.removeFillers()
        #expect(removed == 4)
        #expect(track.segments.map(\.text) == ["So we went home", "Thanks for watching", "Uh-huh, the umbrella is here"])
        // Words that stay keep their original times.
        #expect(track.segments[0].words.map(\.range.start) == [s(0.5), s(1), s(1.5), s(2.5)])
        #expect(track.removeFillers() == 0, "nothing left to remove")
    }
}


/// The shared project-file contract (docs/spec/project.sample.json). Other platforms
/// (Android, macOS, Windows) must read and write this exact shape.
@Suite("Project file contract")
struct ProjectFileContractTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/spec/project.sample.json")

    /// A project that uses every field at least once.
    static func sample() -> Project {
        var p = Project(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Sample",
                        createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        p.modifiedAt = p.createdAt
        p.aspectRatio = .portrait9x16
        p.background = .blur
        p.defaultFit = .fill
        p.defaultAnchor = .center
        var video = MediaItem(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, kind: .video,
                              fileName: "A1B2.mov", naturalSize: CGSize(width: 1080, height: 1920),
                              duration: MediaTime(seconds: 8), hasAudio: true, frameRate: 30, displayName: "Beach")
        video.sourceQuarterTurns = 1
        video.reversedFileName = "rev-A1B2.mov"
        video.denoisedFileNames = [.medium: "nr-medium-A1B2.m4a"]
        let photo = MediaItem(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, kind: .photo,
                              fileName: "C3D4.heic", naturalSize: CGSize(width: 4032, height: 3024),
                              duration: .zero, hasAudio: false, displayName: "Sunset")
        let song = MediaItem(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, kind: .audio,
                             fileName: "music-sunrise-10.m4a", naturalSize: .zero,
                             duration: MediaTime(seconds: 60), hasAudio: true, displayName: "Sunrise Drive")
        p.media = [video, photo, song]

        var v = VideoClip(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, mediaID: video.id, kind: .video,
                          sourceRange: MediaTimeRange(start: MediaTime(seconds: 1), duration: MediaTime(seconds: 4)))
        v.speed = 1.5
        v.noiseReduction = .medium
        v.transform.crop = CropRect(x: 0, y: 0.1, width: 1, height: 0.8)
        v.transform.quarterTurns = 0
        v.transform.fit = .fill
        v.transform.anchor = .center
        v.filter = FilterSetting(filterID: "teal_orange", intensity: 0.8)
        v.adjustments.exposure = 0.2
        v.adjustments.vignette = 0.3
        v.backgroundRemoval = .color(RGBAColor(r: 0, g: 0, b: 0))
        v.reframe = [ReframeKeyframe(time: MediaTime(seconds: 1), centerX: 0.5, centerY: 0.4)]
        v.transitionOut = Transition(kind: .dissolve, duration: MediaTime(seconds: 0.5))
        var anim = ClipAnimation()
        anim.entrance = .zoomIn
        anim.combo = .pulse
        v.animation = anim
        var ph = VideoClip(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, mediaID: photo.id, kind: .photo,
                           sourceRange: MediaTimeRange(start: .zero, duration: MediaTime(seconds: 3)))
        ph.photoMotion = .kenBurns
        p.clips = [v, ph]

        var music = AudioClip(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, mediaID: song.id, role: .music,
                              sourceRange: MediaTimeRange(start: .zero, duration: MediaTime(seconds: 60)), start: .zero)
        music.volume = 0.7
        music.fadeOut = MediaTime(seconds: 1.5)
        music.autoDuck = true
        music.duckLevel = 0.25
        music.name = "Sunrise Drive"
        music.fitsVideo = true
        p.audioClips = [music]

        var text = TextOverlay(id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!, text: "Hello",
                               range: MediaTimeRange(start: .zero, duration: MediaTime(seconds: 3)))
        text.style.outlineColor = .black
        text.style.outlineWidth = 0.08
        text.anchor = .top
        var tanim = ClipAnimation()
        tanim.entrance = .pop
        tanim.exit = .fade
        tanim.inDuration = 0.4
        tanim.outDuration = 0.4
        text.animation = tanim
        text.animationIn = .none
        text.animationOut = .none
        p.textOverlays = [text]

        p.captions.segments = [CaptionSegment(id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!, words: [
            CaptionWord(text: "Hello", range: MediaTimeRange(start: MediaTime(seconds: 0.5), duration: MediaTime(seconds: 0.4))),
            CaptionWord(text: "there", range: MediaTimeRange(start: MediaTime(seconds: 0.9), duration: MediaTime(seconds: 0.4))),
        ])]
        p.captions.preset = .karaoke
        var mark = Watermark()
        mark.text = "@cutline"
        p.watermark = mark
        return p
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    @Test func sampleFileStillDecodesToTheSameProject() throws {
        let sample = Self.sample()
        if !FileManager.default.fileExists(atPath: Self.fixture.path) {
            // First run writes the contract file; commit it.
            try Self.encoder().encode(sample).write(to: Self.fixture)
        }
        let data = try Data(contentsOf: Self.fixture)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == sample, "docs/spec/project.sample.json no longer matches the model")
    }
}
