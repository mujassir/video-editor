package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.PointF
import android.media.FaceDetector
import android.media.MediaMetadataRetriever
import com.mujassir.cutline.core.ColorAdjustments
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.ReframeKeyframe
import com.mujassir.cutline.core.VideoClip
import java.io.File
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Auto Enhance (ENH-1, IMPLEMENTATION §10.2): pure maths on a few frames. */
object AutoEnhance {
    data class Stats(val meanLuma: Double, val lumaStdDev: Double, val meanSaturation: Double, val redBlueBalance: Double, val shadowsP10: Double)

    fun stats(frame: Bitmap): Stats {
        val small = Bitmap.createScaledBitmap(frame, 64, 64, true)
        val px = IntArray(64 * 64)
        small.getPixels(px, 0, 64, 0, 0, 64, 64)
        val lumas = DoubleArray(px.size)
        var sat = 0.0; var rb = 0.0
        px.forEachIndexed { i, p ->
            val r = ((p shr 16) and 0xFF) / 255.0; val g = ((p shr 8) and 0xFF) / 255.0; val b = (p and 0xFF) / 255.0
            lumas[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            val mx = max(r, max(g, b)); val mn = min(r, min(g, b))
            sat += if (mx > 0) (mx - mn) / mx else 0.0
            rb += r - b
        }
        val mean = lumas.average()
        val sd = sqrt(lumas.sumOf { (it - mean) * (it - mean) } / lumas.size)
        val p10 = lumas.sorted()[lumas.size / 10]
        return Stats(mean, sd, sat / px.size, rb / px.size, p10)
    }

    fun average(s: List<Stats>) = Stats(s.map { it.meanLuma }.average(), s.map { it.lumaStdDev }.average(),
        s.map { it.meanSaturation }.average(), s.map { it.redBlueBalance }.average(), s.map { it.shadowsP10 }.average())

    /** The corrections table, each clamped. Replaces the clip's adjustments. */
    fun corrections(s: Stats) = ColorAdjustments(
        exposure = ((0.48 - s.meanLuma) * 1.4).coerceIn(-0.5, 0.6),
        contrast = ((0.22 - s.lumaStdDev) * 2.0).coerceIn(-0.25, 0.35),
        saturation = ((0.38 - s.meanSaturation) * 0.9).coerceIn(-0.2, 0.3),
        warmth = (-s.redBlueBalance * 1.2).coerceIn(-0.3, 0.3),
        shadows = ((0.08 - s.shadowsP10) * 2.5).coerceIn(-0.1, 0.3),
        highlights = if (s.meanLuma > 0.62) -0.25 else 0.0,
    )

    /** Frames: the photo (longer side 512), or 3 frames at 20 / 50 / 80% of the clip. */
    fun analyze(clip: VideoClip, media: MediaItem, file: File): ColorAdjustments? {
        val frames = if (clip.isStill && clip.freezeAt == null) listOfNotNull(Thumbnails.decodeImage(file, 512))
        else {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(file.absolutePath)
                listOf(0.2, 0.5, 0.8).mapNotNull { f ->
                    val t = clip.freezeAt ?: (clip.sourceRange.start + clip.sourceRange.duration.multipliedBy(f))
                    r.getScaledFrameAtTime(t.micros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 256, 256)
                }
            } catch (_: Exception) { emptyList() } finally { r.release() }
        }
        if (frames.isEmpty()) return null
        return corrections(average(frames.map { stats(it) }))
    }
}

/**
 * Auto Reframe (RFR-1, §10.3) with the platform's on-device face detector. Without faces there's
 * no saliency fallback on Android yet (parity table), so the path holds its last position.
 */
object AutoReframe {
    fun keyframes(clip: VideoClip, media: MediaItem, file: File): List<ReframeKeyframe> {
        val count = max(2, floor(clip.timelineDuration.seconds * 4).toInt())
        val r = MediaMetadataRetriever()
        val targets = ArrayList<Pair<MediaTime, Pair<Double, Double>?>>()
        try {
            r.setDataSource(file.absolutePath)
            for (i in 0 until count) {
                val t = clip.sourceRange.start + clip.sourceRange.duration.multipliedBy(i / (count - 1.0))
                val raw = r.getScaledFrameAtTime(t.micros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 512, 512)
                val frame = raw?.let { Thumbnails.upright(it, media.naturalSize.width > media.naturalSize.height, media.sourceQuarterTurns) }
                targets += t to frame?.let { faceCentre(it) }
            }
        } catch (_: Exception) {
            return emptyList()
        } finally {
            r.release()
        }
        var current = targets.firstNotNullOfOrNull { it.second } ?: (0.5 to 0.5)
        return targets.map { (t, target) ->
            if (target != null && (abs(target.first - current.first) > 0.04 || abs(target.second - current.second) > 0.04)) {
                current = (current.first + (target.first - current.first) * 0.35) to (current.second + (target.second - current.second) * 0.35)
            }
            ReframeKeyframe(t, current.first, current.second)
        }
    }

    /** Area-weighted centre of all faces, 0…1 with the origin top-left. */
    private fun faceCentre(frame: Bitmap): Pair<Double, Double>? {
        val w = frame.width and 1.inv()
        val bmp = Bitmap.createScaledBitmap(frame, w.coerceAtLeast(2), frame.height, true).copy(Bitmap.Config.RGB_565, false)
        val faces = arrayOfNulls<FaceDetector.Face>(8)
        val n = runCatching { FaceDetector(bmp.width, bmp.height, faces.size).findFaces(bmp, faces) }.getOrDefault(0)
        if (n == 0) return null
        var sx = 0.0; var sy = 0.0; var total = 0.0
        val p = PointF()
        for (i in 0 until n) {
            val f = faces[i] ?: continue
            f.getMidPoint(p)
            val area = (f.eyesDistance() * 2.0).let { it * it }
            sx += p.x / bmp.width * area; sy += p.y / bmp.height * area; total += area
        }
        return if (total > 0) (sx / total) to (sy / total) else null
    }
}
