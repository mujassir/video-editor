package com.mujassir.cutline.core

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID

// Ports of iOS Tests/EditorKitTests/EditingTests.swift (same suites, same expectations).

private fun s(v: Double) = MediaTime.seconds(v)
private fun s(v: Int) = MediaTime.seconds(v)
private fun r(a: Double, b: Double) = MediaTimeRange.of(s(a), s(b))

private fun video(len: Double, name: String = "v.mov", audio: Boolean = true) =
    MediaItem(kind = MediaKind.VIDEO, fileName = name, naturalSize = Size(1920.0, 1080.0), duration = s(len), hasAudio = audio)

private fun photo(name: String = "a.jpg") =
    MediaItem(kind = MediaKind.PHOTO, fileName = name, naturalSize = Size(10.0, 10.0), duration = MediaTime.ZERO, hasAudio = false)

private fun song(len: Double, name: String = "s.m4a") =
    MediaItem(kind = MediaKind.AUDIO, fileName = name, naturalSize = Size.ZERO, duration = s(len), hasAudio = true)

/** Videos of the given lengths (seconds) on the main track. */
private fun makeProject(vararg lengths: Double): Project =
    lengths.foldIndexed(Project(name = "Test")) { i, p, len -> p.appendingClip(video(len, "v$i.mov")) }

class MediaTimeTest {
    @Test fun secondsRoundTrip() {
        assertEquals(90_000L, s(1.5).ticks)
        assertEquals(1.5, s(1.5).seconds, 0.0)
    }

    @Test fun frameSnapping() {
        assertEquals(s(1.0), s(1.01).snappedToFrame(30))
        assertEquals(MediaTime(62_000), s(1.02).snappedToFrame(30))
    }

    @Test fun timecodeFormatting() {
        assertTrue(s(75.25).timecode in setOf("1:15.2", "1:15.3"))
        assertEquals("0:00.0", s(0).timecode)
    }

    @Test fun codableIsCompactInteger() {
        assertEquals("120000", Json.encodeToString(MediaTime.serializer(), s(2)))
    }
}

class TimelineLayoutTest {
    @Test fun clipsAreBackToBack() {
        val layout = makeProject(2.0, 3.0, 4.0).layout
        assertEquals(s(9), layout.duration)
        assertEquals(listOf(s(0), s(2), s(5)), layout.entries.map { it.range.start })
        assertEquals(listOf(s(2), s(5)), layout.cutTimes)
    }

    @Test fun transitionsOverlapClips() {
        var p = makeProject(2.0, 3.0)
        p = p.settingTransition(Transition(TransitionKind.DISSOLVE, s(0.5)), p.clips[0].id)
        assertEquals(s(4.5), p.layout.duration)
        assertEquals(s(1.5), p.layout.entries[1].range.start)
    }

    @Test fun transitionIsClampedToHalfTheShortestClip() {
        var p = makeProject(1.0, 3.0)
        p = p.settingTransition(Transition(TransitionKind.FADE, s(2)), p.clips[0].id)
        assertEquals(s(0.5), p.layout.entries[0].overlapOut)
    }

    @Test fun speedChangesDuration() {
        var p = makeProject(4.0)
        val id = p.clips[0].id
        p = p.settingSpeed(2.0, id); assertEquals(s(2), p.layout.duration)
        p = p.settingSpeed(0.5, id); assertEquals(s(8), p.layout.duration)
        p = p.settingSpeed(100.0, id); assertEquals(10.0, p.clips[0].speed, 0.0)
    }
}

class SplitTest {
    @Test fun splitsClipAtPlayhead() {
        val newID = UUID.randomUUID()
        val p = makeProject(4.0).splitting(s(1.5), newID)
        assertEquals(2, p.clips.size)
        assertEquals(r(0.0, 1.5), p.clips[0].sourceRange)
        assertEquals(r(1.5, 4.0), p.clips[1].sourceRange)
        assertEquals(newID, p.clips[1].id)
        assertEquals(s(4), p.layout.duration)
    }

    @Test fun splitRespectsSpeed() {
        var p = makeProject(4.0)
        p = p.settingSpeed(2.0, p.clips[0].id).splitting(s(0.5))   // 0.5 s on the timeline = 1 s of source
        assertEquals(s(1), p.clips[0].sourceRange.duration)
        assertEquals(s(1), p.clips[1].sourceRange.start)
        assertEquals(s(2), p.layout.duration)
    }

    @Test fun splitReversedClip() {
        var p = makeProject(4.0)
        p = p.settingReversed(true, p.clips[0].id).splitting(s(1))
        assertEquals(r(3.0, 4.0), p.clips[0].sourceRange)
        assertEquals(r(0.0, 3.0), p.clips[1].sourceRange)
    }

    @Test fun splitInSecondClip() {
        val p = makeProject(2.0, 3.0).splitting(s(3))
        assertEquals(3, p.clips.size)
        assertEquals(r(0.0, 1.0), p.clips[1].sourceRange)
        assertEquals(r(1.0, 3.0), p.clips[2].sourceRange)
    }

    @Test fun refusesTinySplits() {
        val p = makeProject(4.0)
        assertThrows(EditError.TooShort::class.java) { p.splitting(s(0.05)) }
        assertThrows(EditError.OutOfRange::class.java) { p.splitting(s(10)) }
    }

    @Test fun splitMovesTransitionToRightHalf() {
        var p = makeProject(4.0, 4.0)
        p = p.settingTransition(Transition(TransitionKind.FADE), p.clips[0].id).splitting(s(1))
        assertNull(p.clips[0].transitionOut)
        assertEquals(TransitionKind.FADE, p.clips[1].transitionOut?.kind)
    }
}

class TrimTest {
    @Test fun trimLeadingAndTrailing() {
        var p = makeProject(10.0)
        val id = p.clips[0].id
        p = p.trimming(id, TrimEdge.LEADING, s(2)).trimming(id, TrimEdge.TRAILING, s(-3.0))
        assertEquals(r(2.0, 7.0), p.clips[0].sourceRange)
    }

    @Test fun trimIsClampedToSource() {
        var p = makeProject(10.0)
        val id = p.clips[0].id
        p = p.trimming(id, TrimEdge.LEADING, s(-5.0)).trimming(id, TrimEdge.TRAILING, s(5))
        assertEquals(r(0.0, 10.0), p.clips[0].sourceRange)
        p = p.trimming(id, TrimEdge.LEADING, s(20))
        assertEquals(MINIMUM_CLIP_DURATION, p.clips[0].sourceRange.duration)
    }

    @Test fun trimReversedLeadingEdgeRemovesSourceEnd() {
        var p = makeProject(10.0)
        val id = p.clips[0].id
        p = p.settingReversed(true, id).trimming(id, TrimEdge.LEADING, s(2))
        assertEquals(r(0.0, 8.0), p.clips[0].sourceRange)
    }

    @Test fun photosCanBeLengthened() {
        var p = Project(name = "P").appendingClip(photo())
        p = p.trimming(p.clips[0].id, TrimEdge.TRAILING, s(2))
        assertEquals(s(5), p.layout.duration)
    }
}

class ArrangeTest {
    @Test fun deleteDuplicateMove() {
        var p = makeProject(1.0, 2.0, 3.0)
        val ids = p.clips.map { it.id }
        p = p.deletingClip(ids[1])
        assertEquals(listOf(ids[0], ids[2]), p.clips.map { it.id })
        val copy = UUID.randomUUID()
        p = p.duplicatingClip(ids[0], copy)
        assertEquals(listOf(ids[0], copy, ids[2]), p.clips.map { it.id })
        p = p.movingClip(ids[2], 0)
        assertEquals(listOf(ids[2], ids[0], copy), p.clips.map { it.id })
        assertEquals(s(5), p.layout.duration)
    }

    @Test fun freezeFrameInsertsStill() {
        val freeze = UUID.randomUUID()
        val p = makeProject(4.0).insertingFreezeFrame(s(2), freezeID = freeze)
        assertEquals(3, p.clips.size)
        assertEquals(freeze, p.clips[1].id)
        assertEquals(s(2), p.clips[1].freezeAt)
        assertEquals(s(5.5), p.layout.duration)
    }

    @Test fun extractAudioMutesClipAndAddsLane() {
        val audioID = UUID.randomUUID()
        var p = makeProject(2.0, 3.0)
        p = p.extractingAudio(p.clips[1].id, audioID)
        assertTrue(p.clips[1].isMuted)
        val audio = p.audio(audioID)!!
        assertEquals(s(2), audio.start)
        assertEquals(s(3), audio.sourceRange.duration)
    }
}

class RippleDeleteTest {
    @Test fun removesRangesAndClosesGaps() {
        val p = makeProject(10.0).rippleDeleting(listOf(r(2.0, 3.0), r(6.0, 8.0)))
        assertEquals(s(7), p.layout.duration)
        assertEquals(listOf(r(0.0, 2.0), r(3.0, 6.0), r(8.0, 10.0)), p.clips.map { it.sourceRange })
    }

    @Test fun removesAcrossClipBoundaries() {
        val p = makeProject(3.0, 3.0).rippleDeleting(listOf(r(2.0, 4.0)))
        assertEquals(s(4), p.layout.duration)
        assertEquals(2, p.clips.size)
        assertEquals(s(2), p.clips[0].sourceRange.end)
        assertEquals(s(1), p.clips[1].sourceRange.start)
    }

    @Test fun mergesOverlappingRanges() {
        assertEquals(listOf(r(1.0, 4.0), r(6.0, 7.0)), mergeRanges(listOf(r(1.0, 3.0), r(2.0, 4.0), r(6.0, 7.0))))
    }

    @Test fun shiftsTextAndCaptions() {
        var p = makeProject(10.0).addingText("Hello", s(5), s(2))
        p = p.copy(captions = p.captions.copy(segments = listOf(CaptionSegment(words = listOf(
            CaptionWord("gone", r(1.2, 1.6)), CaptionWord("kept", r(4.0, 4.5)),
        )))))
        p = p.rippleDeleting(listOf(r(1.0, 2.0)))
        assertEquals(s(4), p.textOverlays[0].range.start)
        assertEquals(listOf("kept"), p.captions.segments[0].words.map { it.text })
        assertEquals(s(3), p.captions.segments[0].words[0].range.start)
    }
}

class BeatSyncTest {
    @Test fun cutsLandOnBeats() {
        val beats = (0 until 20).map { s(it * 0.5) }
        val (p, aligned) = makeProject(2.3, 1.8, 3.0).syncingCutsToBeats(beats)
        assertEquals(2, aligned)
        for (cut in p.layout.cutTimes) assertEquals("cut $cut is not on a beat", 0L, cut.ticks % s(0.5).ticks)
    }

    @Test fun doesNotExceedSourceLength() {
        val (p, _) = makeProject(2.3, 2.0).syncingCutsToBeats(listOf(s(3)))
        assertEquals(s(2.3), p.clips[0].sourceRange.duration)
    }
}

class PersistenceTest {
    @Test fun saveLoadRoundTrip() {
        val root = Files.createTempDirectory("projects").toFile()
        try {
            val store = ProjectStore(root)
            var p = store.create("Trip")
            p = p.appendingClip(video(5.0, "a.mov")).addingText("Title", MediaTime.ZERO)
                .copy(background = CanvasBackground.Color(RGBAColor.WHITE))
            store.save(p)
            assertEquals(p, store.load(p.id))
            assertEquals(listOf(p.id), store.listProjects().map { it.id })
            val copy = store.duplicate(p.id)
            assertEquals("Trip Copy", copy.name)
            assertEquals(2, store.listProjects().size)
            store.delete(p.id)
            assertEquals(listOf(copy.id), store.listProjects().map { it.id })
        } finally {
            root.deleteRecursively()
        }
    }
}

class UndoTest {
    @Test fun undoRedoRestoresSnapshots() {
        val session = EditSession(makeProject(4.0))
        session.apply("Split") { it.splitting(s(2)) }
        assertEquals(2, session.project.clips.size)
        assertEquals("Split", session.undoLabel)
        session.undo(); assertEquals(1, session.project.clips.size)
        session.redo(); assertEquals(2, session.project.clips.size)
    }

    @Test fun failedEditLeavesNoHistory() {
        val session = EditSession(makeProject(4.0))
        assertThrows(EditError::class.java) { session.apply("Split") { it.splitting(s(99)) } }
        assertFalse(session.canUndo)
    }

    @Test fun coalescedSliderChangesAreOneStep() {
        val session = EditSession(makeProject(4.0))
        val id = session.project.clips[0].id
        for (k in 1..10) {
            session.applyCoalescing("Exposure", "exp-$id") { p ->
                p.updatingClip(id) { it.copy(adjustments = it.adjustments.copy(exposure = k / 10.0)) }
            }
        }
        session.undo()
        assertFalse("one step only", session.canUndo)
        assertEquals(0.0, session.project.clips[0].adjustments.exposure, 0.0)
    }

    @Test fun selectionClearsWhenClipDisappears() {
        val session = EditSession(makeProject(4.0, 2.0))
        val id = session.project.clips[1].id
        session.selection = Selection.Clip(id)
        session.apply("Delete") { it.deletingClip(id) }
        assertEquals(Selection.None, session.selection)
    }

    @Test fun historyIsLimitedTo200Steps() {
        val session = EditSession(makeProject(4.0))
        val id = session.project.clips[0].id
        repeat(250) { k -> session.apply("Speed") { it.settingSpeed(1.0 + (k + 1) / 1000.0, id) } }
        var n = 0
        while (session.canUndo) { session.undo(); n++ }
        assertEquals(200, n)
    }
}

class CanvasTest {
    @Test fun renderSizes() {
        assertEquals(Size(1080.0, 1440.0), AspectRatio.PORTRAIT_3X4.renderSize(1080))
        assertEquals(Size(1080.0, 1920.0), AspectRatio.PORTRAIT_9X16.renderSize(1080))
        assertEquals(Size(1280.0, 720.0), AspectRatio.LANDSCAPE_16X9.renderSize(720))
        assertEquals(listOf("9:16", "3:4", "1:1", "4:5", "16:9"), AspectRatio.entries.map { it.raw })
    }
}

class PhotoDurationTest {
    @Test fun clampsAndAppliesToAllPhotos() {
        var p = Project(name = "P").appendingClip(photo("a.jpg")).appendingClip(video(4.0, audio = false)).appendingClip(photo("b.jpg"))
        p = p.settingStillDuration(s(100), p.clips[0].id); assertEquals(s(30), p.clips[0].timelineDuration)
        p = p.settingStillDuration(s(0.1), p.clips[0].id); assertEquals(s(0.5), p.clips[0].timelineDuration)
        p = p.settingStillDuration(s(5), p.clips[1].id); assertEquals("videos are untouched", s(4), p.clips[1].timelineDuration)
        p = p.settingStillDuration(s(2), p.clips[2].id, allPhotos = true)
        assertEquals(s(2), p.clips[0].timelineDuration); assertEquals(s(2), p.clips[2].timelineDuration)
        assertEquals(s(8), p.layout.duration)
    }
}

class AudioEditingTest {
    /** 10 s of video plus a 30 s song. */
    private fun project(): Pair<Project, UUID> {
        val item = song(30.0, "song.m4a")
        val clip = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(10)),
            start = MediaTime.ZERO, beats = (0 until 60).map { s(it * 0.5) })
        val p = Project(name = "P").appendingClip(video(10.0, audio = false)).let { it.copy(media = it.media + item) }.addingAudio(clip)
        return p to clip.id
    }

    @Test fun trimStartAndEndWithinSong() {
        var (p, id) = project()
        p = p.settingAudioSourceRange(id, r(2.0, 8.0)); assertEquals(r(2.0, 8.0), p.audioClips[0].sourceRange)
        p = p.settingAudioSourceRange(id, r(-5.0, 99.0)); assertEquals("clamped to the song", r(0.0, 30.0), p.audioClips[0].sourceRange)
    }

    @Test fun slideSectionKeepsLength() {
        var (p, id) = project()
        p = p.slidingAudioContent(id, s(12)); assertEquals(r(12.0, 22.0), p.audioClips[0].sourceRange)
        p = p.slidingAudioContent(id, s(28)); assertEquals("can't run past the song end", r(20.0, 30.0), p.audioClips[0].sourceRange)
        assertEquals(s(0), p.audioClips[0].timelineBeats.first())
    }

    @Test fun moveSplitDuplicate() {
        var (p, id) = project()
        p = p.movingAudio(id, s(1)); assertEquals(s(1), p.audioClips[0].start)
        val right = UUID.randomUUID()
        p = p.splittingAudio(id, s(4), right)
        assertEquals(2, p.audioClips.size)
        assertEquals(r(0.0, 3.0), p.audioClips[0].sourceRange)
        val rc = p.audio(right)!!
        assertEquals(s(4), rc.start); assertEquals(r(3.0, 10.0), rc.sourceRange)
        val p2 = p
        assertThrows(EditError.TooShort::class.java) { p2.splittingAudio(id, s(1.05)) }
        val copy = UUID.randomUUID()
        p = p.duplicatingAudio(right, copy)
        val c = p.audio(copy)!!
        assertEquals(rc.timelineRange.end, c.start); assertEquals(rc.sourceRange, c.sourceRange); assertEquals(rc.lane, c.lane)
    }
}

class EmptyProjectTest {
    @Test fun emptyUntilSomethingIsAdded() {
        val p = Project(name = "P")
        assertTrue(p.isEmptyEdit)
        assertFalse(p.addingText("Hi", MediaTime.ZERO).isEmptyEdit)
    }
}

class MusicFullLengthTest {
    private fun project(video: Double, songLen: Double, stored: Double? = null): Project {
        val item = song(songLen, "song.m4a")
        val clip = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(stored ?: songLen)),
            start = MediaTime.ZERO, fitsVideo = true)
        return Project(name = "P").appendingClip(video(video, audio = false)).let { it.copy(media = it.media + item) }.addingAudio(clip)
    }

    @Test fun longSongKeepsItsFullLengthOnTheTimeline() {
        val p = project(60.0, 180.0).refittingMusic()
        assertEquals(s(180), p.audioClips[0].sourceRange.duration)
        assertEquals("timeline shows the whole song", s(180), p.timelineDuration)
        assertEquals("preview and export stop at the end of the video", s(60), p.duration)
    }

    @Test fun olderProjectsTrimmedToTheVideoGetTheWholeSongBack() {
        assertEquals(s(180), project(60.0, 180.0, 60.0).refittingMusic().audioClips[0].sourceRange.duration)
    }

    @Test fun cutPiecesAreSeparateClips() {
        var p = project(60.0, 180.0)
        val id = p.audioClips[0].id
        val right = UUID.randomUUID()
        p = p.splittingAudio(id, s(40), right).refittingMusic()
        assertEquals(2, p.audioClips.size)
        assertEquals(r(0.0, 40.0), p.audioClips[0].sourceRange)
        val piece = p.audio(right)!!
        assertEquals(s(40), piece.start); assertEquals(r(40.0, 180.0), piece.sourceRange)
        p = p.splittingAudio(right, s(120))
        assertEquals(3, p.audioClips.size)
    }

    @Test fun cuttingSectionedMusicMapsPlayedTimeToTheSong() {
        var p = project(60.0, 30.0)
        val id = p.audioClips[0].id
        p = p.addingAudioMarker(id, s(10)).addingAudioMarker(id, s(20)).settingAudioSectionDeleted(id, 1, true)
        val right = UUID.randomUUID()
        p = p.splittingAudio(id, s(15), right)   // 5 s into the 20–30 part
        assertEquals(s(25), p.audioClips[0].sourceRange.end)
        assertEquals(s(15), p.audioClips[0].playedDuration)
        val piece = p.audio(right)!!
        assertEquals(r(25.0, 30.0), piece.sourceRange); assertEquals(s(5), piece.playedDuration)
    }

    @Test fun editsDoNotTrimMusicToTheVideo() {
        val session = EditSession(project(60.0, 180.0))
        session.apply("Add photo") { it.appendingClip(photo(), photoDuration = s(10)) }
        assertEquals(s(180), session.project.audioClips[0].sourceRange.duration)
        assertEquals(s(70), session.project.duration)
    }
}

class MoveAudioToStartTest {
    @Test fun closesTheGapBeforeTheClip() {
        val item = song(60.0)
        val first = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(5)), start = MediaTime.ZERO)
        val late = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(5)), start = s(20))
        var p = Project(name = "P", media = listOf(item)).addingAudio(first).addingAudio(late)
        assertNull(p.audioGapStart(first.id))
        assertEquals(s(5), p.audioGapStart(late.id))
        p = p.movingAudioToGapStart(late.id)
        assertEquals(s(5), p.audio(late.id)!!.start)
        assertNull(p.audioGapStart(late.id))
        assertEquals(p, p.movingAudioToGapStart(late.id))
        p = p.deletingAudio(first.id)
        assertEquals(MediaTime.ZERO, p.audioGapStart(late.id))
        p = p.movingAudioToGapStart(late.id)
        assertEquals(MediaTime.ZERO, p.audio(late.id)!!.start)
    }
}

class RepeatAudioTest {
    private fun project(): Pair<Project, AudioClip> {
        val item = song(60.0)
        val clip = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(s(5), s(8)),
            start = MediaTime.ZERO, fadeOut = s(1.5), fitsVideo = false)
        return Project(name = "P").appendingClip(video(25.0, audio = false)).let { it.copy(media = it.media + item) }.addingAudio(clip) to clip
    }

    @Test fun `MUS-7 fills to the video end`() {
        val (p0, clip) = project()
        val (p, added) = p0.repeatingAudio(clip.id)
        // 0–8, 8–16, 16–24, 24–25 (last cut at the end).
        assertEquals(3, added)
        val sorted = p.audioClips.sortedBy { it.start }
        assertEquals(listOf(s(0), s(8), s(16), s(24)), sorted.map { it.start })
        assertEquals(MediaTimeRange(s(5), s(1)), sorted.last().sourceRange)
        assertTrue(sorted.all { it.sourceRange.start == s(5) && it.lane == 0 })
        assertTrue(sorted.dropLast(1).all { it.fadeOut == MediaTime.ZERO })
        assertEquals(s(1.5), sorted.last().fadeOut)
        assertEquals("already reaches the end", 0, p.repeatingAudio(clip.id).second)
    }

    @Test fun `MUS-7 repeating again extends the chain without overlaps`() {
        val (p0, clip) = project()
        // Shorter video first: one copy, then the video gets longer.
        var p = p0.updatingClip(p0.clips[0].id) { it.copy(sourceRange = it.sourceRange.copy(duration = s(12))) }
        p = p.repeatingAudio(clip.id).first
        assertEquals(2, p.audioClips.size)
        p = p.updatingClip(p.clips[0].id) { it.copy(sourceRange = it.sourceRange.copy(duration = s(25))) }
        val (again, added) = p.repeatingAudio(clip.id)
        assertEquals(2, added)
        val sorted = again.audioClips.sortedBy { it.start }
        assertEquals(listOf(s(0), s(8), s(12), s(20)), sorted.map { it.start })
        assertTrue("no overlaps", sorted.zipWithNext().all { (a, b) -> a.timelineRange.end <= b.start })
        assertEquals(s(1.5), sorted.last().fadeOut)
    }
}

class AudioSectionTest {
    private fun project(): Pair<Project, UUID> {
        val item = song(60.0)
        val clip = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(30)),
            start = MediaTime.ZERO, fitsVideo = true)
        return Project(name = "P").appendingClip(video(30.0, audio = false)).let { it.copy(media = it.media + item) }.addingAudio(clip) to clip.id
    }

    @Test fun markersSplitIntoSections() {
        var (p, id) = project()
        p = p.addingAudioMarker(id, s(10)).addingAudioMarker(id, s(20))
        val secs = p.audioClips[0].resolvedSections
        assertEquals(listOf(s(0), s(10), s(20)), secs.map { it.start })
        assertEquals(listOf(s(10), s(20), s(30)), secs.map { it.end })
        assertFalse(p.audioClips[0].followsVideo)
        val p2 = p
        assertThrows(EditError.TooShort::class.java) { p2.addingAudioMarker(id, s(10.05)) }
        p = p.removingAudioMarker(id, 0); assertEquals(2, p.audioClips[0].resolvedSections.size)
        p = p.clearingAudioMarkers(id); assertNull(p.audioClips[0].sections)
    }

    @Test fun deleteAndVolumePerSection() {
        var (p, id) = project()
        p = p.addingAudioMarker(id, s(10)).addingAudioMarker(id, s(20)).settingAudioSectionDeleted(id, 1, true)
        assertEquals(s(20), p.audioClips[0].playedDuration)
        assertEquals(s(20), p.audioClips[0].timelineRange.duration)
        p = p.settingAudioSectionVolume(id, 2, 0.4)
        assertEquals(0.4, p.audioClips[0].resolvedSections[2].volume, 0.0)
        p = p.settingAudioSectionDeleted(id, 0, true)
        val p2 = p
        assertThrows(EditError.TooShort::class.java) { p2.settingAudioSectionDeleted(id, 2, true) }
        p = p.settingAudioSectionDeleted(id, 1, false)
        assertEquals(s(20), p.audioClips[0].playedDuration)
    }

    @Test fun trimClipsSections() {
        var (p, id) = project()
        p = p.addingAudioMarker(id, s(10)).settingAudioSourceRange(id, r(5.0, 25.0))
        assertEquals(listOf(s(5), s(10)), p.audioClips[0].resolvedSections.map { it.start })
        assertEquals(s(20), p.audioClips[0].playedDuration)
    }
}

class CaptionTest {
    @Test fun onlyClassicKaraokeAndBold() {
        assertEquals(listOf(CaptionPreset.CLASSIC, CaptionPreset.KARAOKE, CaptionPreset.BOLD), CaptionPreset.entries)
    }

    private fun segment(text: String, start: Double) = CaptionSegment(words = text.split(" ").mapIndexed { i, w ->
        CaptionWord(w, MediaTimeRange(s(start + i * 0.5), s(0.5)))
    })

    @Test fun `CAP-9 removes fillers and keeps timing`() {
        val track = CaptionTrack(segments = listOf(segment("Um, so we went uh home", 0.0), segment("Thanks for watching, ah", 5.0),
            segment("Umm...", 9.0), segment("Uh-huh, the umbrella is here", 10.0)))
        val (out, removed) = track.removingFillers()
        assertEquals(4, removed)
        assertEquals(listOf("So we went home", "Thanks for watching", "Uh-huh, the umbrella is here"), out.segments.map { it.text })
        assertEquals(listOf(s(0.5), s(1), s(1.5), s(2.5)), out.segments[0].words.map { it.range.start })
        assertEquals("nothing left to remove", 0, out.removingFillers().second)
    }
}

class MutedClipDuckingTest {
    /** Two 10 s clips with sound (0–10, 10–20) and one caption spanning 5–15 s. */
    private fun project(): Project {
        val p = Project(name = "P").appendingClip(video(10.0, "a.mov")).appendingClip(video(10.0, "b.mov"))
        return p.copy(captions = p.captions.copy(segments = listOf(CaptionSegment(words = listOf(
            CaptionWord("hello", r(5.15, 10.0)), CaptionWord("there", r(10.0, 14.75)),
        )))))
    }

    @Test fun `CLP-5 ducks over speech when voice is on`() {
        assertEquals(listOf(r(5.0, 15.0)), project().duckingSpeechRanges)
    }

    @Test fun `CLP-5 no ducking over a muted clip`() {
        var p = project()
        p = p.updatingClip(p.clips[1].id) { it.copy(isMuted = true) }
        assertEquals(listOf(r(5.0, 10.0)), p.duckingSpeechRanges)
        p = p.updatingClip(p.clips[0].id) { it.copy(isMuted = true) }
        assertTrue(p.duckingSpeechRanges.isEmpty())
    }

    @Test fun `CLP-5 voiceover over a muted clip still ducks`() {
        var p = project()
        p = p.updatingClip(p.clips[1].id) { it.copy(isMuted = true) }
        val vo = song(3.0, "vo.m4a")
        p = p.copy(media = p.media + vo).addingAudio(AudioClip(mediaID = vo.id, role = AudioClip.Role.VOICEOVER,
            sourceRange = MediaTimeRange(MediaTime.ZERO, s(3)), start = s(11)))
        assertEquals(listOf(r(5.0, 10.0), r(11.0, 14.0)), p.duckingSpeechRanges)
    }

    @Test fun subtractRemovesCoveredParts() {
        assertEquals(listOf(r(0.0, 2.0), r(3.0, 8.0)), subtractRanges(listOf(r(0.0, 10.0)), listOf(r(2.0, 3.0), r(8.0, 12.0))))
    }
}

class HasVideoClipsTest {
    @Test fun `TBR-1 only video clips count`() {
        var p = Project(name = "P")
        assertFalse(p.hasVideoClips)
        p = p.appendingClip(photo()).appendingClip(photo())
        assertFalse("photos only", p.hasVideoClips)
        p = p.appendingClip(video(5.0))
        assertTrue(p.hasVideoClips)
        p = p.copy(clips = p.clips.dropLast(1))
        assertFalse(p.hasVideoClips)
    }

    @Test fun `TBR-1 freeze frames don't count`() {
        val p = Project(name = "P").appendingClip(video(5.0))
        assertFalse(p.copy(clips = listOf(p.clips[0].copy(freezeAt = s(1)))).hasVideoClips)
    }
}

class RecentAudioStoreTest {
    private val dir: File = Files.createTempDirectory("recent").toFile()
    private var now = Instant.parse("2026-11-16T10:00:00Z")
    private val recent = RecentAudioStore(File(dir, "RecentAudio")) { now.also { now = now.plusSeconds(1) } }

    private fun file(name: String) = File(dir, "$name.m4a").also { it.writeText(name) }

    @Test fun `MUS-10 keeps the five newest with their own copies`() {
        for (i in 1..7) recent.add(file("song$i"), "Song $i", s(60 + i))
        val list = recent.entries
        assertEquals(listOf("Song 7", "Song 6", "Song 5", "Song 4", "Song 3"), list.map { it.name })
        File(dir, "song7.m4a").delete()
        assertTrue(recent.file(list[0]).exists())
        assertEquals(5, recent.root.listFiles()!!.count { it.name.endsWith(".m4a") })
        assertTrue("ISO 8601 dates", File(recent.root, "recent.json").readText().contains("\"2026-11-16T10:00"))
    }

    @Test fun `MUS-10 using a track again moves it to the top`() {
        recent.add(file("a"), "A", s(30))
        recent.add(file("b"), "B", s(40))
        val a = recent.entries.last()
        recent.add(recent.file(a), "A", s(30))
        assertEquals(listOf("A", "B"), recent.entries.map { it.name })
        assertEquals(a.id, recent.entries[0].id)
    }

    @Test fun `MUS-10 same name different length is a different track`() {
        recent.add(file("v1"), "Video sound", s(12))
        recent.add(file("v2"), "Video sound", s(20))
        assertEquals(2, recent.entries.size)
    }
}

class StartHereTest {
    /** A 15 s video and a 180 s song at 0:00. */
    private fun project(): Pair<Project, UUID> {
        val item = song(180.0)
        val clip = AudioClip(mediaID = item.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(180)),
            start = MediaTime.ZERO, fadeOut = s(1.5))
        return Project(name = "P").appendingClip(video(15.0)).let { it.copy(media = it.media + item) }.addingAudio(clip) to clip.id
    }

    @Test fun `MUS-11 skips the beginning and moves to zero`() {
        val (p0, id) = project()
        val kept = UUID.randomUUID()
        val p = p0.startingAudioHere(id, s(25), kept)
        assertEquals(1, p.audioClips.size)
        val clip = p.audioClips[0]
        assertEquals(kept, clip.id)
        assertEquals(MediaTime.ZERO, clip.start)
        assertEquals(r(25.0, 180.0), clip.sourceRange)
        assertEquals(START_HERE_FADE_IN, clip.fadeIn)
        assertEquals(s(1.5), clip.fadeOut)
    }

    @Test fun `MUS-11 picks a part from the middle`() {
        val (p0, id) = project()
        val p = p0.startingAudioHere(id, s(70))
        assertEquals(MediaTime.ZERO, p.audioClips[0].start)
        assertEquals(s(70), p.audioClips[0].sourceRange.start)
        assertEquals(s(15), p.duration)
    }

    @Test fun `MUS-11 moves only back to the previous clip on its lane`() {
        val (p0, id) = project()
        val second = UUID.randomUUID()
        val p = p0.splittingAudio(id, s(10), second).startingAudioHere(second, s(40))
        val moved = p.audioClips.first { it.id != id }
        assertEquals(s(10), moved.start)
        assertEquals(s(40), moved.sourceRange.start)
    }

    @Test fun `MUS-11 refuses near the edges`() {
        val (p, id) = project()
        assertThrows(EditError.TooShort::class.java) { p.startingAudioHere(id, s(0.1)) }
    }

    @Test fun `MUS-11 is one undo step`() {
        val (p, id) = project()
        val session = EditSession(p)
        session.apply("Start here") { it.startingAudioHere(id, s(25)) }
        session.undo()
        assertEquals(p.audioClips, session.project.audioClips)
    }
}

class DragReorderTest {
    private fun withSlides(vararg lengths: Double): Project {
        val img = MediaItem(kind = MediaKind.PHOTO, fileName = "card.png", naturalSize = Size(1080.0, 1080.0), duration = MediaTime.ZERO, hasAudio = false)
        return makeProject(*lengths)
            .upsertingTitleCard(TitleCard(TitleCard.Placement.OPENING, "Hi"), img, s(3))
            .upsertingTitleCard(TitleCard(TitleCard.Placement.CLOSING, "Bye"), img, s(2))
    }

    @Test fun `TML-13 strip geometry`() {
        assertEquals(58.0, ReorderStrip.PITCH, 0.0)
        assertEquals(174.0, ReorderStrip.tileX(3), 0.0)
        assertEquals(226.0, ReorderStrip.width(4), 0.0)
        assertEquals(0.0, ReorderStrip.width(0), 0.0)
    }

    @Test fun `TML-13 slot from tile centre`() {
        val all = 0..4
        assertEquals(0, ReorderStrip.slot(26.0, all))
        assertEquals(0, ReorderStrip.slot(26.0 + 28, all))
        assertEquals(1, ReorderStrip.slot(26.0 + 30, all))
        assertEquals(3, ReorderStrip.slot(26.0 + 58 * 3, all))
        assertEquals(0, ReorderStrip.slot(-500.0, all))
        assertEquals(4, ReorderStrip.slot(5000.0, all))
        assertEquals(1, ReorderStrip.slot(0.0, 1..3))
        assertEquals(3, ReorderStrip.slot(5000.0, 1..3))
    }

    @Test fun `TML-13 slides can't be dragged`() {
        val p = withSlides(1.0, 2.0, 3.0)
        assertEquals(1..3, p.movableClipIndices)
        assertFalse(p.canReorder(p.clips[0].id))
        assertFalse(p.canReorder(p.clips[4].id))
        assertTrue(p.canReorder(p.clips[2].id))
        val single = makeProject(1.0)
        assertFalse(single.canReorder(single.clips[0].id))
        assertEquals(1, withSlides(1.0).movableClipIndices.count())
    }

    @Test fun `TML-13 drop keeps slides at the ends`() {
        var p = withSlides(1.0, 2.0, 3.0)
        val opening = p.clips[0].id; val closing = p.clips[4].id; val moved = p.clips[1].id
        p = p.movingClip(moved, ReorderStrip.slot(5000.0, p.movableClipIndices))
        assertEquals(moved, p.clips[3].id)
        assertEquals(opening, p.clips.first().id)
        assertEquals(closing, p.clips.last().id)
    }

    @Test fun `TML-13 last clip loses transition`() {
        var p = makeProject(2.0, 2.0, 2.0)
        p = p.copy(clips = p.clips.replacing(0, p.clips[0].copy(transitionOut = Transition(TransitionKind.FADE, s(0.5)))))
        val id = p.clips[0].id
        p = p.movingClip(id, 2)
        assertEquals(id, p.clips.last().id)
        assertNull(p.clips.last().transitionOut)
    }
}

class DenoiseModelTest {
    @Test fun `DNS-1 project level overrides clips and clears their older value`() {
        var p = makeProject(4.0, 4.0)
        p = p.updatingClip(p.clips[0].id) { it.copy(noiseReduction = NoiseReduction.HIGH) }
        assertEquals(NoiseReduction.HIGH, p.noiseReduction(p.clips[0]))
        p = p.settingNoiseReduction(NoiseReduction.LOW, mapOf(p.clips[0].mediaID to "nr2-low-a.m4a"))
        assertEquals(NoiseReduction.LOW, p.noiseReduction(p.clips[0]))
        assertTrue(p.clips.all { it.noiseReduction == null })
        assertEquals("nr2-low-a.m4a", p.media[0].denoisedFileNames?.get(NoiseReduction.LOW))
        assertEquals(2, p.denoiseSources.size)
    }
}

/** Ports of iOS SpeedRetimeTests (SPD-4, SPD-5). */
class SpeedRetimeTest {
    private fun word(text: String, a: Double, b: Double) = CaptionWord(text, r(a, b))

    private fun Project.withPhoto(): Project = appendingClip(photo())

    @Test fun `SPD-4 applies to every video clip and skips stills`() {
        var p = makeProject(4.0, 4.0).withPhoto()
        p = p.insertingFreezeFrame(s(1))
        assertEquals(3, p.speedAdjustableClipCount) // two videos, one split into two pieces
        p = p.settingSpeedForAllClips(2.0)
        for (clip in p.clips) assertEquals(if (clip.isStill) 1.0 else 2.0, clip.speed, 0.0)
        // 8 s of video at 2× = 4 s, plus the 3 s photo and the 1.5 s freeze frame.
        assertEquals(s(8.5), p.layout.duration)
        p = p.settingSpeedForAllClips(50.0)
        assertTrue(p.clips.filter { !it.isStill }.all { it.speed == 10.0 })
    }

    @Test fun `SPD-4 is one undo step`() {
        var start = makeProject(4.0, 4.0, 4.0)
        start = start.copy(captions = start.captions.copy(segments = listOf(CaptionSegment(words = listOf(word("hi", 9.0, 10.0))))))
        val session = EditSession(start)
        session.apply("Speed") { it.settingSpeedForAllClips(2.0) }
        assertEquals(s(6), session.project.layout.duration)
        assertEquals(r(4.5, 5.0), session.project.captions.segments[0].range)
        session.undo()
        assertEquals(start.clips, session.project.clips)
        assertEquals(start.captions, session.project.captions)
        assertFalse(session.canUndo)
    }

    @Test fun `SPD-5 captions stay on their speech`() {
        var p = makeProject(4.0, 4.0, 4.0)
        p = p.copy(captions = p.captions.copy(segments = listOf(
            CaptionSegment(words = listOf(word("before", 1.0, 2.0))),
            CaptionSegment(words = listOf(word("on", 5.0, 6.0), word("clip", 6.0, 7.5))),
            CaptionSegment(words = listOf(word("after", 9.0, 10.0))),
        )))
        p = p.settingSpeed(2.0, p.clips[1].id)
        assertEquals(listOf(r(1.0, 2.0), r(4.5, 5.0), r(5.0, 5.75), r(7.0, 8.0)), p.captions.segments.flatMap { it.words }.map { it.range })
        p = p.settingSpeed(1.0, p.clips[1].id)
        assertEquals(listOf(r(1.0, 2.0), r(5.0, 6.0), r(6.0, 7.5), r(9.0, 10.0)), p.captions.segments.flatMap { it.words }.map { it.range })
    }

    @Test fun `SPD-5 slow motion spreads captions`() {
        var p = makeProject(4.0, 4.0)
        p = p.copy(captions = p.captions.copy(segments = listOf(CaptionSegment(words = listOf(word("slow", 1.0, 2.0), word("next", 5.0, 6.0))))))
        p = p.settingSpeed(0.5, p.clips[0].id)
        assertEquals(listOf(r(2.0, 4.0), r(9.0, 10.0)), p.captions.segments[0].words.map { it.range })
    }

    @Test fun `SPD-5 apply to all halves every time`() {
        var p = makeProject(4.0, 4.0)
        p = p.copy(captions = p.captions.copy(segments = listOf(CaptionSegment(words = listOf(word("a", 1.0, 3.0), word("b", 6.0, 7.0))))))
        p = p.settingSpeedForAllClips(2.0)
        assertEquals(listOf(r(0.5, 1.5), r(3.0, 3.5)), p.captions.segments[0].words.map { it.range })
    }

    @Test fun `SPD-5 text follows within its duration limits`() {
        var p = makeProject(4.0, 4.0, 4.0)
        p = p.addingText("On", s(4), s(2))
        val onClip = p.textOverlays[0].id
        p = p.addingText("After", s(9), s(1))
        val after = p.textOverlays[1].id
        p = p.addingText("Tiny", s(4), s(0.6))
        val tiny = p.textOverlays[2].id
        p = p.settingSpeed(4.0, p.clips[1].id)
        fun range(id: UUID) = p.textOverlays.first { it.id == id }.range
        assertEquals(r(4.0, 4.5), range(onClip))
        assertEquals(r(6.0, 7.0), range(after))
        assertEquals(MediaTimeRange(s(4), s(0.5)), range(tiny))
        assertEquals(3, p.textOverlays.size)
        p = p.settingSpeed(0.1, p.clips[1].id)
        assertEquals(s(20), range(onClip).duration)
        assertEquals(MediaTimeRange(s(4 + 40 + 1), s(1)), range(after))
    }

    @Test fun `SPD-5 voiceover moves music stays`() {
        var p = makeProject(4.0, 4.0)
        val song = song(60.0, "m.m4a")
        p = p.copy(media = p.media + song, audioClips = listOf(
            AudioClip(mediaID = song.id, role = AudioClip.Role.MUSIC, sourceRange = MediaTimeRange(MediaTime.ZERO, s(60)), start = s(1)),
            AudioClip(mediaID = song.id, role = AudioClip.Role.VOICEOVER, sourceRange = MediaTimeRange(MediaTime.ZERO, s(3)), start = s(6)),
        ))
        p = p.settingSpeed(2.0, p.clips[0].id)
        assertEquals(s(1), p.audioClips[0].start)
        assertEquals(s(4), p.audioClips[1].start)
        assertEquals(s(3), p.audioClips[1].sourceRange.duration)
    }

    @Test fun `SPD-5 transition overlap belongs to the incoming clip`() {
        var p = makeProject(4.0, 4.0)
        p = p.settingTransition(Transition(TransitionKind.FADE, s(1)), p.clips[0].id)
        p = p.copy(captions = p.captions.copy(segments = listOf(CaptionSegment(words = listOf(word("x", 3.5, 4.0))))))
        p = p.settingSpeed(2.0, p.clips[1].id)
        assertEquals(s(3), p.layout.entries[1].range.start)
        assertEquals(r(3.25, 3.5), p.captions.segments[0].range)
    }

    @Test fun `SPD-5 times past the video shift and stills dont change`() {
        var p = makeProject(4.0).withPhoto()
        p = p.copy(captions = p.captions.copy(segments = listOf(CaptionSegment(words = listOf(word("photo", 5.0, 6.0), word("end", 8.0, 9.0))))))
        p = p.settingSpeed(2.0, p.clips[0].id)
        assertEquals(listOf(r(3.0, 4.0), r(6.0, 7.0)), p.captions.segments[0].words.map { it.range })
        val before = p
        p = p.settingSpeed(3.0, p.clips[1].id)
        assertEquals(before, p)
    }
}
