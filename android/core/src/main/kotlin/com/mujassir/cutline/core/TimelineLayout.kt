package com.mujassir.cutline.core

import java.util.UUID

/**
 * Resolved positions on the main track (IMPLEMENTATION §6.1). Clips play back to back; a
 * transition overlaps two clips by its duration, clamped to half of either clip.
 */
class TimelineLayout(clips: List<VideoClip>) {
    data class Entry(
        val clipID: UUID,
        val index: Int,
        /** Range on the timeline, including transition overlaps. */
        val range: MediaTimeRange,
        /** Overlap with the next clip. */
        val overlapOut: MediaTime,
        /** Overlap with the previous clip. */
        val overlapIn: MediaTime,
    )

    val entries: List<Entry>
    val duration: MediaTime

    init {
        val out = ArrayList<Entry>(clips.size)
        var cursor = MediaTime.ZERO
        var previousOverlap = MediaTime.ZERO
        clips.forEachIndexed { i, clip ->
            val d = clip.timelineDuration
            var overlap = MediaTime.ZERO
            val t = clip.transitionOut
            if (i + 1 < clips.size && t != null) {
                val next = clips[i + 1].timelineDuration
                val limit = MediaTime(minOf(d.ticks, next.ticks) / 2)
                overlap = MediaTime.min(t.duration, limit)
            }
            out += Entry(clip.id, i, MediaTimeRange(cursor, d), overlap, previousOverlap)
            cursor = cursor + d - overlap
            previousOverlap = overlap
        }
        entries = out
        duration = out.lastOrNull()?.range?.end ?: MediaTime.ZERO
    }

    fun entry(clipID: UUID): Entry? = entries.firstOrNull { it.clipID == clipID }

    /** The clip whose range contains `time`. During a transition the incoming clip wins. */
    fun entryAt(time: MediaTime): Entry? {
        entries.lastOrNull { time in it.range }?.let { return it }
        val last = entries.lastOrNull()
        if (last != null && time >= last.range.end && time == duration) return last
        return null
    }

    /** Start of every clip after the first. */
    val cutTimes: List<MediaTime> get() = entries.drop(1).map { it.range.start }
}

val Project.layout: TimelineLayout get() = TimelineLayout(clips)

/** A main-track video clip that plays motion (TBR-1: Captions need one). */
val Project.hasVideoClips: Boolean get() = clips.any { it.kind == MediaKind.VIDEO && !it.isStill }

/** Nothing added yet (LIB-4). */
val Project.isEmptyEdit: Boolean
    get() = clips.isEmpty() && audioClips.isEmpty() && textOverlays.isEmpty() && captions.segments.isEmpty()

/** Length of the edit: the main track, or the end of a voiceover past it. What's exported. */
val Project.duration: MediaTime
    get() {
        var d = layout.duration
        for (a in audioClips) if (a.role == AudioClip.Role.VOICEOVER) d = MediaTime.max(d, a.timelineRange.end)
        return d
    }

/** What the timeline shows: the edit plus music that runs past its end (MUS-3). */
val Project.timelineDuration: MediaTime
    get() = audioClips.fold(duration) { acc, a -> MediaTime.max(acc, a.timelineRange.end) }
