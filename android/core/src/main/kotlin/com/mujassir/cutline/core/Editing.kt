package com.mujassir.cutline.core

import java.util.UUID

/** Why an edit failed. Failing edits leave the project unchanged. */
sealed class EditError(message: String) : Exception(message) {
    data object ClipNotFound : EditError("clip not found")
    data object TooShort : EditError("too short")
    data object OutOfRange : EditError("out of range")
}

/** Geometry of the drag-to-reorder thumbnail strip (TML-13, IMPLEMENTATION §6.2). */
object ReorderStrip {
    const val TILE_SIZE = 52.0
    const val SPACING = 6.0
    const val PITCH = TILE_SIZE + SPACING
    fun tileX(slot: Int) = slot * PITCH
    fun width(count: Int) = if (count > 0) count * PITCH - SPACING else 0.0

    /** Landing slot for a floating tile whose centre is `centreX` from the strip start. */
    fun slot(centreX: Double, movable: IntRange): Int {
        if (movable.isEmpty()) return movable.first
        val raw = roundHalfAway((centreX - TILE_SIZE / 2) / PITCH).toInt()
        return raw.coerceIn(movable.first, movable.last)
    }
}

internal fun <T> List<T>.replacing(index: Int, value: T): List<T> = toMutableList().also { it[index] = value }
internal fun <T> List<T>.inserting(index: Int, value: T): List<T> = toMutableList().also { it.add(index, value) }
internal fun <T> List<T>.removingAt(index: Int): List<T> = toMutableList().also { it.removeAt(index) }

/** Shortest clip the editor produces. */
val MINIMUM_CLIP_DURATION = MediaTime.seconds(0.1)
/** Shortest audio piece (MUS). */
val MINIMUM_AUDIO_DURATION = MediaTime.seconds(0.2)
val STILL_DURATION_MIN = MediaTime.seconds(0.5)
val STILL_DURATION_MAX = MediaTime.seconds(30)
val TEXT_DURATION_MIN = MediaTime.seconds(0.5)
val TEXT_DURATION_MAX = MediaTime.seconds(30)
/** Fade-in given by Start Here (MUS-11). */
val START_HERE_FADE_IN = MediaTime.seconds(0.3)

enum class TrimEdge { LEADING, TRAILING }

// MARK: - Main track

/** Appends media to the main track (photos default to 3 s); audio goes to a free lane. */
fun Project.appendingClip(item: MediaItem, photoDuration: MediaTime = MediaTime.seconds(3), clipID: UUID = UUID.randomUUID()): Project {
    val media = if (media.any { it.id == item.id }) media else media + item
    var p = copy(media = media)
    when (item.kind) {
        MediaKind.AUDIO -> return p.addingAudio(
            AudioClip(id = clipID, mediaID = item.id, role = AudioClip.Role.MUSIC,
                sourceRange = MediaTimeRange(MediaTime.ZERO, item.duration), start = MediaTime.ZERO)
        )
        MediaKind.VIDEO, MediaKind.PHOTO -> {
            val range = MediaTimeRange(MediaTime.ZERO, if (item.kind == MediaKind.VIDEO) item.duration else photoDuration)
            var t = ClipTransform()
            defaultFit?.let { t = t.copy(fit = it) }
            defaultAnchor?.let { t = t.copy(anchor = it) }
            p = p.copy(clips = clips + VideoClip(id = clipID, mediaID = item.id, kind = item.kind, sourceRange = range, transform = t))
        }
    }
    return p
}

/** Adds audio on the first lane where it doesn't collide. */
fun Project.addingAudio(clip: AudioClip): Project {
    var lane = 0
    while (audioClips.any { it.lane == lane && it.timelineRange.intersection(clip.timelineRange) != null }) lane++
    return copy(audioClips = audioClips + clip.copy(lane = lane))
}

/** Splits the clip under `time`; the right-hand piece gets `newID`. CLP-1. */
fun Project.splitting(time: MediaTime, newID: UUID = UUID.randomUUID()): Project {
    val entry = layout.entryAt(time) ?: throw EditError.OutOfRange
    val local = time - entry.range.start
    val duration = entry.range.duration
    if (local < MINIMUM_CLIP_DURATION || duration - local < MINIMUM_CLIP_DURATION) throw EditError.TooShort
    val original = clips[entry.index]
    var left = original.copy(transitionOut = null)
    var right = original.copy(id = newID)
    if (original.isStill) {
        left = left.copy(sourceRange = left.sourceRange.copy(duration = local))
        right = right.copy(sourceRange = right.sourceRange.copy(duration = duration - local))
    } else {
        val sourceLocal = local.multipliedBy(original.speed)
        if (original.isReversed) {
            val splitPoint = original.sourceRange.end - sourceLocal
            left = left.copy(sourceRange = MediaTimeRange.of(splitPoint, original.sourceRange.end))
            right = right.copy(sourceRange = MediaTimeRange.of(original.sourceRange.start, splitPoint))
        } else {
            val splitPoint = original.sourceRange.start + sourceLocal
            left = left.copy(sourceRange = MediaTimeRange.of(original.sourceRange.start, splitPoint))
            right = right.copy(sourceRange = MediaTimeRange.of(splitPoint, original.sourceRange.end))
        }
        left = left.copy(reframe = original.reframe.filter { it.time in left.sourceRange })
        right = right.copy(reframe = original.reframe.filter { it.time in right.sourceRange })
    }
    return copy(clips = clips.replacing(entry.index, left).inserting(entry.index + 1, right))
}

/** Moves a clip edge by `delta` of timeline time (positive = right), clamped. */
fun Project.trimming(clipID: UUID, edge: TrimEdge, delta: MediaTime): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    var clip = clips[index]
    val item = mediaItem(clip.mediaID) ?: throw EditError.ClipNotFound
    val minSource = if (clip.isStill) MINIMUM_CLIP_DURATION else MINIMUM_CLIP_DURATION.multipliedBy(clip.speed)
    if (clip.isStill) {
        val change = if (edge == TrimEdge.TRAILING) delta else -delta
        val newDuration = MediaTime.max(clip.sourceRange.duration + change, minSource)
        clip = clip.copy(sourceRange = clip.sourceRange.copy(duration = MediaTime.min(newDuration, MediaTime.seconds(60))))
        return copy(clips = clips.replacing(index, clip))
    }
    val sourceDelta = delta.multipliedBy(clip.speed)
    var start = clip.sourceRange.start
    var end = clip.sourceRange.end
    // On the timeline, a reversed clip's leading edge is its source end.
    val movesSourceStart = (edge == TrimEdge.LEADING) != clip.isReversed
    if (movesSourceStart) {
        start += if (clip.isReversed) -sourceDelta else sourceDelta
        start = start.clamped(MediaTime.ZERO, end - minSource)
    } else {
        end += if (clip.isReversed) -sourceDelta else sourceDelta
        end = end.clamped(start + minSource, item.duration)
    }
    val range = MediaTimeRange.of(start, end)
    clip = clip.copy(sourceRange = range, reframe = clip.reframe.filter { it.time in range })
    return copy(clips = clips.replacing(index, clip))
}

/** Sets a clip's source range directly (precise trim, engine only). */
fun Project.settingSourceRange(clipID: UUID, range: MediaTimeRange): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    val item = mediaItem(clips[index].mediaID) ?: throw EditError.ClipNotFound
    val start = range.start.clamped(MediaTime.ZERO, item.duration)
    val end = range.end.clamped(start, item.duration)
    if (end - start < MINIMUM_CLIP_DURATION) throw EditError.TooShort
    return copy(clips = clips.replacing(index, clips[index].copy(sourceRange = MediaTimeRange.of(start, end))))
}

fun Project.deletingClip(clipID: UUID): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    var list = clips.removingAt(index)
    if (index > 0 && index == list.size) list = list.replacing(index - 1, list[index - 1].copy(transitionOut = null))
    return copy(clips = list)
}

fun Project.duplicatingClip(clipID: UUID, newID: UUID = UUID.randomUUID()): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    return copy(clips = clips.inserting(index + 1, clips[index].copy(id = newID)))
}

/** Moves a clip; the clip that ends up last never keeps a transition (CLP-4). */
fun Project.movingClip(clipID: UUID, toIndex: Int): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    val list = clips.toMutableList()
    val clip = list.removeAt(index)
    list.add(toIndex.coerceIn(0, list.size), clip)
    if (list.isNotEmpty()) list[list.lastIndex] = list.last().copy(transitionOut = null)
    return copy(clips = list)
}

/** Clips that can be reordered: everything between the opening and closing slides (TML-13). */
val Project.movableClipIndices: IntRange
    get() {
        val lower = if (clips.firstOrNull()?.titleCard?.placement == TitleCard.Placement.OPENING) 1 else 0
        val upper = if (clips.lastOrNull()?.titleCard?.placement == TitleCard.Placement.CLOSING) clips.size - 1 else clips.size
        return lower until maxOf(lower, upper)
    }

fun Project.canReorder(clipID: UUID): Boolean {
    val index = clipIndex(clipID) ?: return false
    val movable = movableClipIndices
    return clips[index].titleCard == null && index in movable && movable.count() > 1
}

// MARK: - Speed / reverse / freeze

fun Project.settingSpeed(speed: Double, clipID: UUID): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    if (clips[index].isStill) return this
    return copy(clips = clips.replacing(index, clips[index].copy(speed = speed.coerceIn(0.1, 10.0))))
}

fun Project.settingReversed(reversed: Boolean, clipID: UUID): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    val c = clips[index]
    if (c.kind != MediaKind.VIDEO || c.freezeAt != null) return this
    return copy(clips = clips.replacing(index, c.copy(isReversed = reversed)))
}

/** Inserts a still of the frame under `time`, splitting the clip around it (FRZ-1). */
fun Project.insertingFreezeFrame(
    time: MediaTime, duration: MediaTime = MediaTime.seconds(1.5),
    freezeID: UUID = UUID.randomUUID(), splitID: UUID = UUID.randomUUID(),
): Project {
    val entry = layout.entryAt(time) ?: throw EditError.OutOfRange
    val clip = clips[entry.index]
    if (clip.kind != MediaKind.VIDEO || clip.freezeAt != null) throw EditError.OutOfRange
    val local = time - entry.range.start
    val sourceTime = clip.sourceTime(local)
    val freeze = clip.copy(
        id = freezeID, freezeAt = sourceTime, sourceRange = MediaTimeRange(sourceTime, duration),
        transitionOut = null, isReversed = false, speed = 1.0, reframe = emptyList(),
    )
    return when {
        local < MINIMUM_CLIP_DURATION -> copy(clips = clips.inserting(entry.index, freeze))
        entry.range.duration - local < MINIMUM_CLIP_DURATION -> copy(clips = clips.inserting(entry.index + 1, freeze))
        else -> {
            val split = splitting(time, splitID)
            split.copy(clips = split.clips.inserting(entry.index + 1, freeze))
        }
    }
}

// MARK: - Per-clip settings

fun Project.updatingClip(clipID: UUID, change: (VideoClip) -> VideoClip): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    return copy(clips = clips.replacing(index, change(clips[index])))
}

/** How long a photo or freeze frame shows (0.5–30 s), optionally for every photo (DUR). */
fun Project.settingStillDuration(duration: MediaTime, clipID: UUID, allPhotos: Boolean = false): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    if (!clips[index].isStill) return this
    val d = duration.clamped(STILL_DURATION_MIN, STILL_DURATION_MAX)
    val list = clips.mapIndexed { i, c ->
        if (i == index || (allPhotos && c.kind == MediaKind.PHOTO)) c.copy(sourceRange = c.sourceRange.copy(duration = d)) else c
    }
    return copy(clips = list)
}

/** Canvas-wide fit (CNV-2): every clip except slides, and clips added later. */
fun Project.settingContentFit(fit: ContentFit, anchor: ContentAnchor): Project = copy(
    defaultFit = fit, defaultAnchor = anchor,
    clips = clips.map { if (it.titleCard == null) it.copy(transform = it.transform.copy(fit = fit, anchor = anchor)) else it },
)

fun Project.settingPhotoMotion(motion: PhotoMotion?, clipID: UUID, allPhotos: Boolean = false): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    if (!clips[index].isStill) return this
    val value = if (motion == PhotoMotion.NONE) null else motion
    return copy(clips = clips.mapIndexed { i, c -> if (i == index || (allPhotos && c.kind == MediaKind.PHOTO)) c.copy(photoMotion = value) else c })
}

fun Project.settingTransition(transition: Transition?, afterClip: UUID): Project {
    val index = clipIndex(afterClip) ?: throw EditError.ClipNotFound
    if (index + 1 >= clips.size) return this
    return copy(clips = clips.replacing(index, clips[index].copy(transitionOut = transition)))
}

// MARK: - Ripple delete (engine only)

fun mergeRanges(ranges: List<MediaTimeRange>): List<MediaTimeRange> {
    val out = ArrayList<MediaTimeRange>()
    for (r in ranges.sortedBy { it.start }) {
        val last = out.lastOrNull()
        if (last != null && r.start <= last.end) out[out.lastIndex] = MediaTimeRange.of(last.start, MediaTime.max(last.end, r.end))
        else out += r
    }
    return out
}

fun subtractRanges(ranges: List<MediaTimeRange>, cuts: List<MediaTimeRange>): List<MediaTimeRange> {
    if (cuts.isEmpty()) return ranges
    val merged = mergeRanges(cuts)
    val out = ArrayList<MediaTimeRange>()
    for (r in ranges) {
        var start = r.start
        for (c in merged) {
            if (c.end > start && c.start < r.end) {
                if (c.start > start) out += MediaTimeRange.of(start, c.start)
                start = MediaTime.max(start, c.end)
            }
        }
        if (start < r.end) out += MediaTimeRange.of(start, r.end)
    }
    return out
}

/** Removes timeline ranges from the main track and closes the gaps; later text and captions shift. */
fun Project.rippleDeleting(ranges: List<MediaTimeRange>): Project {
    var p = copy(clips = clips.map { it.copy(transitionOut = null) })
    for (range in mergeRanges(ranges).filter { !it.isEmpty }.reversed()) {
        val cut = range.intersection(MediaTimeRange(MediaTime.ZERO, p.layout.duration)) ?: continue
        p = runCatching { p.splitting(cut.end) }.getOrDefault(p)
        p = runCatching { p.splitting(cut.start) }.getOrDefault(p)
        val doomed = p.layout.entries.filter { e ->
            val overlap = e.range.intersection(cut) ?: return@filter false
            e.range.duration - overlap.duration < MINIMUM_CLIP_DURATION
        }.map { it.clipID }.toSet()
        p = p.copy(clips = p.clips.filter { it.id !in doomed }).shiftingOverlays(cut)
    }
    return p
}

private fun Project.shiftingOverlays(cut: MediaTimeRange): Project {
    fun shifted(t: MediaTime) = when {
        t >= cut.end -> t - cut.duration
        t > cut.start -> cut.start
        else -> t
    }
    val texts = textOverlays.map { it.copy(range = MediaTimeRange.of(shifted(it.range.start), shifted(it.range.end))) }
        .filter { it.range.duration >= MINIMUM_CLIP_DURATION }
    val segments = captions.segments.map { seg ->
        seg.copy(words = seg.words.mapNotNull { w ->
            val r = MediaTimeRange.of(shifted(w.range.start), shifted(w.range.end))
            if (r.isEmpty) null else w.copy(range = r)
        })
    }.filter { it.words.isNotEmpty() }
    val audio = audioClips.map {
        if (it.role == AudioClip.Role.VOICEOVER || it.role == AudioClip.Role.EXTRACTED) it.copy(start = shifted(it.start)) else it
    }
    return copy(textOverlays = texts, captions = captions.copy(segments = segments), audioClips = audio)
}

/**
 * Where music ducks (IMPLEMENTATION §9.3): each caption widened to [start − 0.15 s, end + 0.25 s]
 * and merged, minus parts over clips whose Voice is off (CLP-5) unless other sound plays there.
 */
val Project.duckingSpeechRanges: List<MediaTimeRange>
    get() {
        val speech = mergeRanges(captions.segments.map {
            MediaTimeRange.of(it.range.start - MediaTime.seconds(0.15), it.range.end + MediaTime.seconds(0.25))
        })
        if (speech.isEmpty()) return emptyList()
        val silent = ArrayList<MediaTimeRange>()
        val voiced = ArrayList<MediaTimeRange>()
        for (e in layout.entries) {
            val clip = clips[e.index]
            val hasSound = mediaItem(clip.mediaID)?.hasAudio ?: false
            val plays = clip.hasAudio && hasSound && !clip.isMuted && !clip.isReversed && clip.volume > 0
            if (plays) voiced += e.range else if (clip.isMuted) silent += e.range
        }
        for (a in audioClips) if (a.role == AudioClip.Role.VOICEOVER || a.role == AudioClip.Role.EXTRACTED) voiced += a.timelineRange
        val quiet = subtractRanges(mergeRanges(silent), mergeRanges(voiced))
        return subtractRanges(speech, quiet)
    }

// MARK: - Beat sync (engine only)

/** Moves each cut to the nearest beat. Returns (project, cuts aligned). */
fun Project.syncingCutsToBeats(beats: List<MediaTime>, minimumClip: MediaTime = MediaTime.seconds(0.4)): Pair<Project, Int> {
    val sorted = beats.sorted()
    if (sorted.isEmpty() || clips.size < 2) return this to 0
    val list = clips.map { it.copy(transitionOut = null) }.toMutableList()
    var aligned = 0
    var cursor = MediaTime.ZERO
    for (i in 0 until list.size - 1) {
        val clip = list[i]
        val currentEnd = cursor + clip.timelineDuration
        val maxDuration = when {
            clip.isStill -> MediaTime.seconds(60)
            else -> mediaItem(clip.mediaID)?.let { item ->
                val available = if (clip.isReversed) clip.sourceRange.end else item.duration - clip.sourceRange.start
                available.dividedBy(clip.speed)
            } ?: clip.timelineDuration
        }
        val target = sorted.filter { it - cursor >= minimumClip && it - cursor <= maxDuration }
            .minByOrNull { absTicks(it - currentEnd) }
        if (target == null) { cursor = currentEnd; continue }
        val newDuration = target - cursor
        list[i] = if (clip.isStill) clip.copy(sourceRange = clip.sourceRange.copy(duration = newDuration)) else {
            val sd = newDuration.multipliedBy(clip.speed)
            if (clip.isReversed) clip.copy(sourceRange = MediaTimeRange.of(clip.sourceRange.end - sd, clip.sourceRange.end))
            else clip.copy(sourceRange = clip.sourceRange.copy(duration = sd))
        }
        aligned++
        cursor = target
    }
    return copy(clips = list) to aligned
}

// MARK: - Text (TXT)

/** Adds text at `time` for 3 s; it pops in and fades out (TXT-1). */
fun Project.addingText(text: String, time: MediaTime, duration: MediaTime = MediaTime.seconds(3), id: UUID = UUID.randomUUID()): Project {
    val overlay = TextOverlay(
        id = id, text = text, range = MediaTimeRange(time, duration),
        animation = ClipAnimation(entrance = ClipEntrance.POP, exit = ClipEntrance.FADE, inDuration = 0.4, outDuration = 0.4),
        animationIn = TextAnimation.NONE, animationOut = TextAnimation.NONE,
    )
    return copy(textOverlays = textOverlays + overlay)
}

fun Project.updatingText(id: UUID, change: (TextOverlay) -> TextOverlay): Project =
    copy(textOverlays = textOverlays.map { if (it.id == id) change(it) else it })

fun Project.settingTextDuration(id: UUID, duration: MediaTime) =
    updatingText(id) { it.copy(range = it.range.copy(duration = duration.clamped(TEXT_DURATION_MIN, TEXT_DURATION_MAX))) }

fun Project.movingText(id: UUID, toStart: MediaTime) =
    updatingText(id) { it.copy(range = it.range.copy(start = MediaTime.max(MediaTime.ZERO, toStart))) }

/** Fixed spot, or nil for free placement (centred again). TXT-5. */
fun Project.settingTextAnchor(id: UUID, anchor: OverlayAnchor?) =
    updatingText(id) { if (anchor == null) it.copy(anchor = null, centerX = 0.5, centerY = 0.5) else it.copy(anchor = anchor) }

/** Copy placed right after the original (TXT-6). */
fun Project.duplicatingText(id: UUID, newID: UUID = UUID.randomUUID()): Project {
    val t = text(id) ?: return this
    return copy(textOverlays = textOverlays + t.copy(id = newID, range = t.range.copy(start = t.range.end)))
}

fun Project.deletingText(id: UUID) = copy(textOverlays = textOverlays.filter { it.id != id })

// MARK: - Slides (TTL)

fun Project.titleCardClip(placement: TitleCard.Placement): VideoClip? = clips.firstOrNull { it.titleCard?.placement == placement }

/** Adds or replaces the opening (first) / closing (last) slide with a rendered image. */
fun Project.upsertingTitleCard(card: TitleCard, image: MediaItem, duration: MediaTime, clipID: UUID = UUID.randomUUID()): Project {
    val media = if (media.any { it.id == image.id }) media else media + image
    val d = duration.clamped(STILL_DURATION_MIN, STILL_DURATION_MAX)
    val i = clips.indexOfFirst { it.titleCard?.placement == card.placement }
    if (i >= 0) {
        val c = clips[i]
        return copy(media = media, clips = clips.replacing(i, c.copy(mediaID = image.id, titleCard = card, sourceRange = c.sourceRange.copy(duration = d))))
    }
    val clip = VideoClip(
        id = clipID, mediaID = image.id, kind = MediaKind.PHOTO, sourceRange = MediaTimeRange(MediaTime.ZERO, d),
        titleCard = card, transform = ClipTransform(fit = ContentFit.FILL),
    )
    return copy(media = media, clips = if (card.placement == TitleCard.Placement.OPENING) listOf(clip) + clips else clips + clip)
}

fun Project.removingTitleCard(placement: TitleCard.Placement): Project {
    val list = clips.filter { it.titleCard?.placement != placement }.toMutableList()
    if (list.isNotEmpty()) list[list.lastIndex] = list.last().copy(transitionOut = null)
    return copy(clips = list)
}

// MARK: - Audio (MUS)

fun Project.updatingAudio(id: UUID, change: (AudioClip) -> AudioClip) =
    copy(audioClips = audioClips.map { if (it.id == id) change(it) else it })

/**
 * Uncut music runs to the end of the song, however long the video is (MUS-3). Runs after every edit.
 */
fun Project.refittingMusic(): Project {
    var changed = false
    val list = audioClips.map { a ->
        if (!a.followsVideo || a.hasSectionEdits) return@map a
        val item = mediaItem(a.mediaID) ?: return@map a
        val length = MediaTime.max(MINIMUM_AUDIO_DURATION, item.duration - a.sourceRange.start)
        if (length != a.sourceRange.duration) { changed = true; a.copy(sourceRange = a.sourceRange.copy(duration = length)) } else a
    }
    return if (changed) copy(audioClips = list) else this
}

private fun Project.audioIndex(id: UUID): Pair<Int, MediaTime> {
    val i = audioClips.indexOfFirst { it.id == id }
    if (i < 0) throw EditError.ClipNotFound
    val item = mediaItem(audioClips[i].mediaID) ?: throw EditError.ClipNotFound
    return i to item.duration
}

fun Project.settingAudioSourceRange(id: UUID, range: MediaTimeRange): Project {
    val (i, total) = audioIndex(id)
    val start = range.start.clamped(MediaTime.ZERO, MediaTime.max(MediaTime.ZERO, total - MINIMUM_AUDIO_DURATION))
    val end = range.end.clamped(start + MINIMUM_AUDIO_DURATION, MediaTime.max(start + MINIMUM_AUDIO_DURATION, total))
    var a = audioClips[i]
    if (MediaTime.min(end, total) != a.sourceRange.end) a = a.copy(fitsVideo = false)
    a = a.copy(sourceRange = MediaTimeRange.of(start, MediaTime.min(end, total)))
    return copy(audioClips = audioClips.replacing(i, a))
}

fun Project.movingAudio(id: UUID, toTimelineStart: MediaTime): Project {
    val (i, _) = audioIndex(id)
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(start = MediaTime.max(MediaTime.ZERO, toTimelineStart))))
}

/** Start of the blank space before an audio clip on its lane, or null when there's no gap (MUS-6). */
fun Project.audioGapStart(id: UUID): MediaTime? {
    val clip = audio(id) ?: return null
    val before = audioClips.filter { it.id != id && it.lane == clip.lane && it.timelineRange.end <= clip.start }
        .maxOfOrNull { it.timelineRange.end } ?: MediaTime.ZERO
    return if (clip.start - before >= MINIMUM_AUDIO_DURATION) before else null
}

/** Move to Start (MUS-6). Unchanged when there's no gap. */
fun Project.movingAudioToGapStart(id: UUID): Project {
    val (i, _) = audioIndex(id)
    val start = audioGapStart(id) ?: return this
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(start = start)))
}

/** Start Here (MUS-11): cut at `time`, drop the part before, move back to the gap start, 0.3 s fade-in. */
fun Project.startingAudioHere(id: UUID, time: MediaTime, rightID: UUID = UUID.randomUUID()): Project {
    val (i, _) = audioIndex(id)
    val original = audioClips[i]
    val before = audioClips.filter { it.id != id && it.lane == original.lane && it.timelineRange.end <= original.start }
        .maxOfOrNull { it.timelineRange.end } ?: MediaTime.ZERO
    val split = splittingAudio(id, time, rightID)
    val list = split.audioClips.filter { it.id != id }.map {
        if (it.id == rightID) it.copy(start = before, fadeIn = MediaTime.min(START_HERE_FADE_IN, MediaTime(it.playedDuration.ticks / 2))) else it
    }
    return split.copy(audioClips = list)
}

/** Cut (MUS-4): splits an audio clip at a timeline time; the right piece gets `rightID`. */
fun Project.splittingAudio(id: UUID, time: MediaTime, rightID: UUID = UUID.randomUUID()): Project {
    val (i, _) = audioIndex(id)
    val clip = audioClips[i]
    val local = time - clip.start
    if (local < MINIMUM_AUDIO_DURATION || clip.playedDuration - local < MINIMUM_AUDIO_DURATION) throw EditError.TooShort
    var cut = clip.sourceRange.start + local
    if (clip.hasSectionEdits) {
        var played = MediaTime.ZERO
        for (s in clip.resolvedSections.filter { !it.deleted }) {
            if (local <= played + s.duration) { cut = s.start + (local - played); break }
            played += s.duration
        }
    }
    val left = clip.copy(fitsVideo = false, sourceRange = MediaTimeRange.of(clip.sourceRange.start, cut), fadeOut = MediaTime.ZERO)
    val right = clip.copy(id = rightID, fitsVideo = false, sourceRange = MediaTimeRange.of(cut, clip.sourceRange.end), start = time, fadeIn = MediaTime.ZERO)
    return copy(audioClips = audioClips.replacing(i, left).inserting(i + 1, right))
}

/** Adds a marker at a song time, splitting the section that contains it (engine only). */
fun Project.addingAudioMarker(id: UUID, time: MediaTime): Project {
    val (i, _) = audioIndex(id)
    val secs = audioClips[i].resolvedSections.toMutableList()
    val k = secs.indexOfFirst { time > it.start + MINIMUM_AUDIO_DURATION && time < it.end - MINIMUM_AUDIO_DURATION }
    if (k < 0) throw EditError.TooShort
    val s = secs[k]
    secs[k] = s.copy(end = time)
    secs.add(k + 1, AudioSection(time, s.end, s.volume, s.deleted))
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(sections = secs, fitsVideo = false)))
}

fun Project.removingAudioMarker(id: UUID, afterIndex: Int): Project {
    val (i, _) = audioIndex(id)
    val secs = audioClips[i].resolvedSections.toMutableList()
    if (afterIndex < 0 || afterIndex + 1 >= secs.size) throw EditError.OutOfRange
    secs[afterIndex] = secs[afterIndex].copy(end = secs[afterIndex + 1].end)
    secs.removeAt(afterIndex + 1)
    val value = if (secs.size == 1 && secs[0].volume == 1.0 && !secs[0].deleted) null else secs
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(sections = value)))
}

fun Project.clearingAudioMarkers(id: UUID): Project {
    val (i, _) = audioIndex(id)
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(sections = null)))
}

fun Project.settingAudioSectionVolume(id: UUID, index: Int, volume: Double): Project {
    val (i, _) = audioIndex(id)
    val secs = audioClips[i].resolvedSections.toMutableList()
    if (index !in secs.indices) throw EditError.OutOfRange
    secs[index] = secs[index].copy(volume = volume.coerceIn(0.0, 2.0))
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(sections = secs, fitsVideo = false)))
}

fun Project.settingAudioSectionDeleted(id: UUID, index: Int, deleted: Boolean): Project {
    val (i, _) = audioIndex(id)
    val secs = audioClips[i].resolvedSections.toMutableList()
    if (index !in secs.indices) throw EditError.OutOfRange
    if (deleted && secs.count { !it.deleted } <= 1) throw EditError.TooShort
    secs[index] = secs[index].copy(deleted = deleted)
    return copy(audioClips = audioClips.replacing(i, audioClips[i].copy(sections = secs, fitsVideo = false)))
}

/**
 * Repeat (MUS-7): copies back to back until the end of the video; the last copy is cut at the end
 * and keeps the fade-out. Repeating again extends the chain of copies already placed after the clip,
 * so copies never overlap. Returns (project, copies added) — 0 when it already reaches the end.
 */
fun Project.repeatingAudio(id: UUID): Pair<Project, Int> {
    val (i, _) = audioIndex(id)
    val videoEnd = layout.duration
    val original = audioClips[i]
    val length = original.playedDuration
    // Follow copies already repeated back to back after this clip.
    var last = i
    while (true) {
        val end = audioClips[last].timelineRange.end
        val n = audioClips.indices.firstOrNull { k ->
            k != last && audioClips[k].lane == original.lane && audioClips[k].mediaID == original.mediaID &&
                absTicks(audioClips[k].start - end) < 60
        } ?: break
        last = n
    }
    if (length < MINIMUM_AUDIO_DURATION || audioClips[last].timelineRange.end >= videoEnd - MINIMUM_AUDIO_DURATION) return this to 0
    val fadeOut = audioClips[last].fadeOut
    val list = audioClips.toMutableList()
    val base = original.copy(fitsVideo = false, fadeOut = MediaTime.ZERO)
    list[i] = base
    list[last] = list[last].copy(fadeOut = MediaTime.ZERO, fitsVideo = false)
    var cursor = list[last].timelineRange.end
    val copies = ArrayList<AudioClip>()
    while (videoEnd - cursor >= MINIMUM_AUDIO_DURATION) {
        var c = base.copy(id = UUID.randomUUID(), start = cursor, fadeIn = MediaTime.ZERO)
        if (!base.hasSectionEdits) c = c.copy(sourceRange = c.sourceRange.copy(duration = MediaTime.min(length, videoEnd - cursor)))
        copies += c
        cursor = c.timelineRange.end
    }
    if (copies.isEmpty()) return this to 0
    copies[copies.lastIndex] = copies.last().copy(fadeOut = fadeOut)
    var p = copy(audioClips = list)
    for (c in copies) {
        val collides = p.audioClips.any { it.lane == c.lane && it.timelineRange.intersection(c.timelineRange) != null }
        p = if (collides) p.addingAudio(c) else p.copy(audioClips = p.audioClips + c)
    }
    return p to copies.size
}

fun Project.duplicatingAudio(id: UUID, newID: UUID = UUID.randomUUID()): Project {
    val (i, _) = audioIndex(id)
    val list = audioClips.toMutableList()
    list[i] = list[i].copy(fitsVideo = false)
    val c = list[i].copy(id = newID, start = list[i].timelineRange.end)
    val collides = list.any { it.lane == c.lane && it.timelineRange.intersection(c.timelineRange) != null }
    return if (collides) copy(audioClips = list).addingAudio(c) else copy(audioClips = list.inserting(i + 1, c))
}

fun Project.deletingAudio(id: UUID) = copy(audioClips = audioClips.filter { it.id != id })

/** Mutes the clip and puts its sound on an audio lane (engine only). */
fun Project.extractingAudio(clipID: UUID, audioID: UUID = UUID.randomUUID()): Project {
    val index = clipIndex(clipID) ?: throw EditError.ClipNotFound
    val clip = clips[index]
    val item = mediaItem(clip.mediaID)
    if (!clip.hasAudio || clip.isReversed || clip.speed != 1.0 || item == null || !item.hasAudio) throw EditError.OutOfRange
    val entry = layout.entry(clipID) ?: throw EditError.ClipNotFound
    val audio = AudioClip(id = audioID, mediaID = clip.mediaID, role = AudioClip.Role.EXTRACTED, sourceRange = clip.sourceRange,
        start = entry.range.start, volume = clip.volume, name = "Extracted audio")
    return copy(clips = clips.replacing(index, clip.copy(isMuted = true))).addingAudio(audio)
}

// MARK: - Denoise (DNS)

/** Sets Denoise for the whole video and records new files; clears every clip's older value. */
fun Project.settingNoiseReduction(level: NoiseReduction?, files: Map<UUID, String> = emptyMap()): Project {
    val p = if (level != null) recordingDenoisedFiles(files, level) else this
    return p.copy(noiseReduction = level, clips = p.clips.map { it.copy(noiseReduction = null) })
}

fun Project.recordingDenoisedFiles(files: Map<UUID, String>, level: NoiseReduction): Project = copy(
    media = media.map { m ->
        val name = files[m.id] ?: return@map m
        m.copy(denoisedFileNames = (m.denoisedFileNames ?: emptyMap()) + (level to name))
    }
)

/** Removes filler words from the captions (CAP-9). Returns (project, removed). */
fun Project.removingCaptionFillers(): Pair<Project, Int> {
    val (track, n) = captions.removingFillers()
    return copy(captions = track) to n
}
