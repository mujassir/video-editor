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
 * Auto Reframe (RFR-1, §10.3): faces first, then classical saliency when no faces
 * (stands in for Vision's objectness saliency until an ML model is bundled).
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
                targets += t to frame?.let { subjectCentre(it) }
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

    /** Faces if present, otherwise the most salient region (§10.3). Origin top-left, 0…1. */
    fun subjectCentre(frame: Bitmap): Pair<Double, Double>? = faceCentre(frame) ?: Saliency.subjectCentre(frame)

    /** Area-weighted centre of all faces, 0…1 with the origin top-left. */
    private fun faceCentre(frame: Bitmap): Pair<Double, Double>? {
        val w = (frame.width and 1.inv()).coerceAtLeast(2)
        val bmp = Bitmap.createScaledBitmap(frame, w, frame.height, true).copy(Bitmap.Config.RGB_565, false)
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

/**
 * Classical saliency fallback for RFR-1 when no faces are found: centre of the window with the
 * highest (local contrast × area). Pure bitmap maths — no network / ML model.
 */
object Saliency {
    fun subjectCentre(frame: Bitmap): Pair<Double, Double>? {
        val tw = 64
        val th = max(2, (64.0 * frame.height / frame.width).toInt())
        val small = Bitmap.createScaledBitmap(frame, tw, th, true)
        val px = IntArray(tw * th)
        small.getPixels(px, 0, tw, 0, 0, tw, th)
        val luma = DoubleArray(tw * th) { i ->
            val p = px[i]
            0.2126 * ((p shr 16) and 0xFF) + 0.7152 * ((p shr 8) and 0xFF) + 0.0722 * (p and 0xFF)
        }
        // Local contrast map (3×3 neighbourhood std-dev).
        val contrast = DoubleArray(tw * th)
        for (y in 1 until th - 1) for (x in 1 until tw - 1) {
            var sum = 0.0; var sum2 = 0.0; var n = 0
            for (dy in -1..1) for (dx in -1..1) {
                val v = luma[(y + dy) * tw + (x + dx)]
                sum += v; sum2 += v * v; n++
            }
            val mean = sum / n
            contrast[y * tw + x] = sqrt(sum2 / n - mean * mean)
        }
        // Sliding windows: pick highest confidence×area (mean contrast × window area).
        val sizes = intArrayOf(12, 18, 24)
        var bestScore = 0.0
        var bestX = 0.5
        var bestY = 0.5
        var found = false
        for (s in sizes) {
            if (s >= tw || s >= th) continue
            for (y in 0..(th - s)) for (x in 0..(tw - s)) {
                var sum = 0.0
                for (yy in y until y + s) for (xx in x until x + s) sum += contrast[yy * tw + xx]
                val mean = sum / (s * s)
                val score = mean * (s * s) // confidence × area proxy
                if (score > bestScore) {
                    bestScore = score
                    bestX = (x + s / 2.0) / tw
                    bestY = (y + s / 2.0) / th
                    found = true
                }
            }
        }
        if (small !== frame) small.recycle()
        // Ignore near-flat frames (nothing stands out). Mean contrast ~0 on flat gray.
        if (!found || bestScore < 2.0) return null
        return bestX to bestY
    }
}
