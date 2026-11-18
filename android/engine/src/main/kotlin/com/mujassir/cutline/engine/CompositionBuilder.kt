package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem as M3Item
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import com.mujassir.cutline.core.AudioClip
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.Size
import com.mujassir.cutline.core.VideoClip
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.core.layout
import com.mujassir.cutline.core.render.LayerAnimation
import com.mujassir.cutline.core.render.LayerGeometry
import com.mujassir.cutline.core.timelineDuration
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/** Live switches the renderer reads every frame (the editor's preview, like iOS RenderToggles). */
class RenderToggles {
    /** PRV-3: clip / text animations and photo motion only while playing or exporting. */
    val animate = AtomicBoolean(false)
}

/**
 * Builds a Media3 [Composition] from a project (IMPLEMENTATION §7–§9).
 *
 * Android differences (parity table): the main track is one sequence, so a transition plays as two
 * halves on either side of the cut (each clip gives up half the overlap) instead of overlapping two
 * clips; the edit's length and every cut time are the same as on iOS.
 */
@UnstableApi
class CompositionBuilder(
    private val store: ProjectStore,
    private val toggles: RenderToggles,
) {
    data class Built(val composition: Composition, val canvas: Size, val overlay: OverlayRenderer)

    /**
     * @param shortEdge 720 for the preview; 720 / 1080 / 2160 for export.
     * @param preview the preview lasts until the end of the music (PRV-8); export stops at the edit's end.
     */
    fun build(project: Project, shortEdge: Int, preview: Boolean): Built {
        val canvas = project.aspectRatio.renderSize(shortEdge)
        val cw = canvas.width.toInt(); val ch = canvas.height.toInt()
        val overlay = OverlayRenderer(cw, ch) { store.mediaFile(it, project.id) }
        val video = videoSequence(project, cw, ch)
        val sequences = mutableListOf(video)
        val end = if (preview) project.timelineDuration else project.duration
        // Denoised clip sound is a separate audio sequence (video keeps the picture track).
        mainTrackCleanedAudio(project, end)?.let { sequences += it }
        audioSequences(project, end).forEach { sequences += it }
        val composition = Composition.Builder(sequences)
            .setEffects(Effects(emptyList(), listOf(overlayEffect(project, overlay, cw, ch))))
            .build()
        return Built(composition, canvas, overlay)
    }

    // MARK: Main track

    private fun videoSequence(project: Project, cw: Int, ch: Int): EditedMediaItemSequence {
        val layout = project.layout
        val items = ArrayList<EditedMediaItem>()
        for (entry in layout.entries) {
            val clip = project.clips[entry.index]
            val media = project.mediaItem(clip.mediaID) ?: continue
            val halfIn = entry.overlapIn.half()
            val halfOut = entry.overlapOut.half()
            val itemDuration = entry.range.duration - halfIn - halfOut
            if (itemDuration <= MediaTime.ZERO) continue
            val layerEffect = ClipLayerEffect(cw, ch, project.background) { timeUs, inW, inH ->
                layerFrame(project, clip, media, entry.range.start, entry.range.duration, entry.overlapIn, entry.overlapOut,
                    timeUs, inW, inH, Size(cw.toDouble(), ch.toDouble()), toggles.animate.get())
            }
            items += if (clip.isStill) stillItem(project, clip, media, itemDuration, layerEffect)
            else videoItem(project, clip, media, halfIn, halfOut, layerEffect)
        }
        if (items.isEmpty()) {
            // An empty edit still needs a video track: one transparent frame's worth of black.
            return EditedMediaItemSequence.Builder(blankItem(cw, ch)).build()
        }
        return EditedMediaItemSequence.Builder(items).experimentalSetForceAudioTrack(true).build()
    }

    private fun stillItem(project: Project, clip: VideoClip, media: MediaItem, duration: MediaTime, effect: Effect): EditedMediaItem {
        val file = when {
            clip.freezeAt != null -> Thumbnails.freezeFrameFile(store.mediaFile(media, project.id), clip.freezeAt!!,
                store.cacheDirectory(project.id), media.naturalSize.width > media.naturalSize.height, media.sourceQuarterTurns)
            else -> store.mediaFile(media, project.id)
        }
        val item = M3Item.Builder().setUri(Uri.fromFile(file)).setImageDurationMs(duration.millis.coerceAtLeast(1)).build()
        return EditedMediaItem.Builder(item)
            .setDurationUs(duration.micros)
            .setFrameRate(project.frameRate)
            .setEffects(Effects(emptyList(), listOf(effect)))
            .build()
    }

    private fun videoItem(project: Project, clip: VideoClip, media: MediaItem, halfIn: MediaTime, halfOut: MediaTime, effect: Effect): EditedMediaItem {
        val reversedFile = media.reversedFileName?.let { store.mediaFile(it, project.id) }?.takeIf { clip.isReversed && it.exists() }
        val cleanedAudio = if (reversedFile == null) noiseFile(project, clip, media) else null
        val src = clip.sourceRange
        val sp = clip.speed
        // Each clip gives up half of each transition overlap (in timeline time → source time).
        var start = src.start + halfIn.multipliedBy(sp)
        var end = src.end - halfOut.multipliedBy(sp)
        val file = if (reversedFile != null) {
            val d = media.duration
            val rs = d - end; val re = d - start
            start = rs; end = re
            reversedFile
        } else {
            store.mediaFile(media, project.id)
        }
        val item = M3Item.Builder().setUri(Uri.fromFile(file))
            .setClippingConfiguration(
                M3Item.ClippingConfiguration.Builder()
                    .setStartPositionUs(start.micros.coerceAtLeast(0))
                    .setEndPositionUs(end.micros)
                    .build()
            ).build()
        val audio = ArrayList<AudioProcessor>()
        val videoEffects = ArrayList<Effect>()
        if (sp != 1.0) {
            val pair = Effects.createExperimentalSpeedChangingEffect(ConstantSpeed(sp.toFloat()))
            audio += pair.first
            videoEffects += pair.second
        }
        videoEffects += effect
        // Original embedded audio only when Denoise hasn't supplied a cleaned copy (DNS-2 / §7).
        val plays = clip.hasAudio && media.hasAudio && !clip.isMuted && clip.volume > 0 &&
            reversedFile == null && cleanedAudio == null
        if (plays && clip.volume != 1.0) audio += GainProcessor(clip.volume.toFloat())
        return EditedMediaItem.Builder(item)
            .setDurationUs(sourceDurationUs(media, end))
            .setRemoveAudio(!plays)
            .setEffects(Effects(audio, videoEffects))
            .build()
    }

    /**
     * Main-track cleaned audio (DNS): one sequence with gaps so timing matches the picture.
     * Source range matches the (half-trimmed) clip, same as the video item.
     */
    private fun mainTrackCleanedAudio(project: Project, end: MediaTime): EditedMediaItemSequence? {
        val layout = project.layout
        val b = EditedMediaItemSequence.Builder(emptyList())
        var cursor = MediaTime.ZERO
        var added = 0
        for (entry in layout.entries) {
            val clip = project.clips[entry.index]
            val media = project.mediaItem(clip.mediaID) ?: continue
            if (clip.isReversed || clip.isMuted || clip.volume <= 0 || !clip.hasAudio || !media.hasAudio) continue
            val cleaned = noiseFile(project, clip, media) ?: continue
            val halfIn = entry.overlapIn.half()
            val halfOut = entry.overlapOut.half()
            val itemDuration = entry.range.duration - halfIn - halfOut
            if (itemDuration <= MediaTime.ZERO) continue
            val timelineStart = entry.range.start + halfIn
            if (timelineStart >= end) break
            if (timelineStart > cursor) b.addGap((timelineStart - cursor).micros)
            val sp = clip.speed
            val srcStart = clip.sourceRange.start + halfIn.multipliedBy(sp)
            val srcEnd = clip.sourceRange.end - halfOut.multipliedBy(sp)
            val length = MediaTime.min(itemDuration, end - timelineStart)
            val srcLength = length.multipliedBy(sp)
            val item = M3Item.Builder().setUri(Uri.fromFile(cleaned))
                .setClippingConfiguration(
                    M3Item.ClippingConfiguration.Builder()
                        .setStartPositionUs(srcStart.micros.coerceAtLeast(0))
                        .setEndPositionUs((srcStart + srcLength).micros)
                        .build()
                ).build()
            val processors = ArrayList<AudioProcessor>()
            if (sp != 1.0) {
                val pair = Effects.createExperimentalSpeedChangingEffect(ConstantSpeed(sp.toFloat()))
                processors += pair.first
            }
            if (clip.volume != 1.0) processors += GainProcessor(clip.volume.toFloat())
            b.addItem(
                EditedMediaItem.Builder(item)
                    .setDurationUs(sourceDurationUs(media, srcStart + srcLength))
                    .setRemoveVideo(true)
                    .setEffects(Effects(processors, emptyList()))
                    .build()
            )
            cursor = timelineStart + length
            added++
        }
        return if (added > 0) b.build() else null
    }

    /**
     * The whole source file's length, which Media3 needs for clipped items: CompositionPlayer adds up
     * each item's clipped length from it and crashes on an unset one. Never shorter than the clip's end,
     * because Media3 also rejects an end past the source length (the probed length can round down).
     */
    private fun sourceDurationUs(media: MediaItem, clipEnd: MediaTime): Long =
        maxOf(media.duration.micros, clipEnd.micros, 1)

    /** DNS: the cleaned file when Denoise is on and it exists. */
    private fun noiseFile(project: Project, clip: VideoClip, media: MediaItem): File? {
        val level = project.noiseReduction(clip) ?: return null
        val name = media.denoisedFileNames?.get(level) ?: return null
        return store.mediaFile(name, project.id).takeIf { it.exists() }
    }

    private fun blankItem(cw: Int, ch: Int): EditedMediaItem {
        val file = File(store.root, "blank-${cw}x$ch.png")
        if (!file.exists()) {
            val b = Bitmap.createBitmap(cw, ch, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLACK) }
            file.outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val item = M3Item.Builder().setUri(Uri.fromFile(file)).setImageDurationMs(100).build()
        return EditedMediaItem.Builder(item).setDurationUs(100_000).setFrameRate(30).build()
    }

    // MARK: Audio clips

    /** One sequence per audio lane: gaps, then each clip's kept part (§7). */
    private fun audioSequences(project: Project, end: MediaTime): List<EditedMediaItemSequence> {
        val out = ArrayList<EditedMediaItemSequence>()
        for (lane in project.audioClips.map { it.lane }.distinct().sorted()) {
            val clips = project.audioClips.filter { it.lane == lane && it.start < end }.sortedBy { it.start }
            if (clips.isEmpty()) continue
            val b = EditedMediaItemSequence.Builder(emptyList())
            var cursor = MediaTime.ZERO
            var added = 0
            for (a in clips) {
                val media = project.mediaItem(a.mediaID) ?: continue
                val file = store.mediaFile(media, project.id)
                if (a.start > cursor) b.addGap((a.start - cursor).micros)
                cursor = MediaTime.max(cursor, a.start)
                for ((range, volume) in playedParts(a)) {
                    val room = end - cursor
                    if (room <= MediaTime.ZERO) break
                    val length = MediaTime.min(range.duration, room)
                    val item = M3Item.Builder().setUri(Uri.fromFile(file))
                        .setClippingConfiguration(M3Item.ClippingConfiguration.Builder()
                            .setStartPositionUs(range.start.micros).setEndPositionUs((range.start + length).micros).build())
                        .build()
                    val gain = EnvelopeProcessor((a.volume * volume).toFloat(), a.fadeIn.seconds, a.fadeOut.seconds,
                        startsClip = range.start == a.resolvedSections.first { !it.deleted }.start,
                        endsClip = range.end == a.resolvedSections.last { !it.deleted }.end, lengthSeconds = length.seconds)
                    b.addItem(EditedMediaItem.Builder(item).setDurationUs(sourceDurationUs(media, range.start + length))
                        .setRemoveVideo(true).setEffects(Effects(listOf(gain), emptyList())).build())
                    cursor += length
                    added++
                }
            }
            if (added > 0) out += b.build()
        }
        return out
    }

    /** Kept parts of an audio clip, in song time, with each section's volume. */
    private fun playedParts(a: AudioClip): List<Pair<com.mujassir.cutline.core.MediaTimeRange, Double>> =
        if (!a.hasSectionEdits) listOf(a.sourceRange to 1.0)
        else a.resolvedSections.filter { !it.deleted }.map { com.mujassir.cutline.core.MediaTimeRange.of(it.start, it.end) to it.volume }

    // MARK: Overlays

    private fun overlayEffect(project: Project, renderer: OverlayRenderer, cw: Int, ch: Int): Effect {
        val buffers = arrayOf(Bitmap.createBitmap(cw, ch, Bitmap.Config.ARGB_8888), Bitmap.createBitmap(cw, ch, Bitmap.Config.ARGB_8888))
        val overlay = object : BitmapOverlay() {
            var flip = 0
            override fun getBitmap(presentationTimeUs: Long): Bitmap {
                // BitmapOverlay re-uploads only when the Bitmap object changes, so alternate two buffers.
                flip = 1 - flip
                renderer.draw(project, MediaTime(presentationTimeUs * MediaTime.TIMESCALE / 1_000_000), toggles.animate.get(), buffers[flip])
                return buffers[flip]
            }
        }
        return OverlayEffect(listOf(overlay))
    }

    companion object {
        /** Parameters for one clip at a composition time (IMPLEMENTATION §8.2, §8.5). */
        fun layerFrame(
            project: Project, clip: VideoClip, media: MediaItem, start: MediaTime, duration: MediaTime,
            overlapIn: MediaTime, overlapOut: MediaTime, timeUs: Long, inputW: Int, inputH: Int, canvas: Size,
            animate: Boolean = true,
        ): LayerFrame {
            val t = MediaTime(timeUs * MediaTime.TIMESCALE / 1_000_000)
            val local = t - start
            val d = duration.seconds
            val l = local.seconds
            var anim = LayerAnimation()
            if (animate) {
                clip.animation?.let { anim = LayerGeometry.combine(anim, LayerGeometry.clipAnimation(it, l, d)) }
                if (clip.isStill) clip.photoMotion?.let { anim = LayerGeometry.combine(anim, LayerGeometry.photoMotion(it, if (d > 0) l / d else 0.0)) }
            }
            // Transitions always apply (two halves around the cut on Android).
            val prev = project.clips.getOrNull(project.clipIndex(clip.id)?.minus(1) ?: -1)?.transitionOut
            if (overlapIn > MediaTime.ZERO && local < overlapIn && prev != null) {
                anim = LayerGeometry.combine(anim, LayerGeometry.transitionAnimation(prev.kind, local.seconds / overlapIn.seconds, incoming = true))
            }
            val out = clip.transitionOut
            if (overlapOut > MediaTime.ZERO && local > duration - overlapOut && out != null) {
                val p = (local - (duration - overlapOut)).seconds / overlapOut.seconds
                anim = LayerGeometry.combine(anim, LayerGeometry.transitionAnimation(out.kind, p, incoming = false))
            }
            // Frames that come back raw (not upright) need the source turns.
            val uprightLandscape = media.naturalSize.width > media.naturalSize.height
            val turns = when {
                clip.isStill || clip.titleCard != null -> 0
                (inputW > inputH) == uprightLandscape || inputW == inputH -> 0     // already upright
                else -> media.sourceQuarterTurns
            }
            val reframe = if (clip.reframe.isNotEmpty()) LayerGeometry.reframeCenter(clip.reframe, clip.sourceTime(local)) else null
            val quad = LayerGeometry.quad(media, clip.transform, turns, canvas, anim, reframe, forceFill = clip.titleCard != null)
            val bg = if (project.background is com.mujassir.cutline.core.CanvasBackground.Blur)
                LayerGeometry.quad(media, clip.transform.copy(scale = 1.0, offsetX = 0.0, offsetY = 0.0), turns, canvas, forceFill = true)
            else null
            return LayerFrame(quad, bg, anim, clip.adjustments, clip.filter?.filterID, clip.filter?.intensity ?: 0.0, l)
        }
    }
}

/** Constant playback speed (SPD). */
@UnstableApi
private class ConstantSpeed(private val speed: Float) : SpeedProvider {
    override fun getSpeed(timeUs: Long) = speed
    override fun getNextSpeedChangeTimeUs(timeUs: Long) = C.TIME_UNSET
}

/** Constant gain on 16-bit PCM (clip volume). */
@UnstableApi
class GainProcessor(private val gain: Float) : BaseAudioProcessor() {
    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val n = inputBuffer.remaining()
        val out = replaceOutputBuffer(n)
        val src = inputBuffer.order(ByteOrder.LITTLE_ENDIAN)
        while (src.remaining() >= 2) {
            val v = (src.short * gain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            out.putShort(v.toShort())
        }
        out.flip()
    }
}

/**
 * Audio clip envelope (§9.2): volume, fade-in at the clip's start and fade-out at its end. The
 * position counts samples since the item started, so after a seek inside a fade the ramp restarts.
 */
@UnstableApi
class EnvelopeProcessor(
    private val volume: Float,
    private val fadeIn: Double,
    private val fadeOut: Double,
    private val startsClip: Boolean,
    private val endsClip: Boolean,
    private val lengthSeconds: Double,
) : BaseAudioProcessor() {
    private var frames = 0L
    private var rate = 44_100
    private var channels = 2

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        rate = inputAudioFormat.sampleRate; channels = inputAudioFormat.channelCount.coerceAtLeast(1)
        return inputAudioFormat
    }

    override fun onFlush() { frames = 0 }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val out = replaceOutputBuffer(inputBuffer.remaining())
        val src = inputBuffer.order(ByteOrder.LITTLE_ENDIAN)
        while (src.remaining() >= 2 * channels) {
            val t = frames.toDouble() / rate
            var g = volume.toDouble()
            if (startsClip && fadeIn > 0 && t < fadeIn) g *= t / fadeIn
            if (endsClip && fadeOut > 0 && t > lengthSeconds - fadeOut) g *= ((lengthSeconds - t) / fadeOut).coerceIn(0.0, 1.0)
            repeat(channels) {
                val v = (src.short * g).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                out.putShort(v.toShort())
            }
            frames++
        }
        out.flip()
    }
}
