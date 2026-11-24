package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PointF
import android.media.FaceDetector
import android.media.MediaMetadataRetriever
import android.util.LruCache
import com.mujassir.cutline.core.MediaTime
import java.io.File
import kotlin.math.max

/**
 * Interim person mask for Cutout (CUT / §10.4) until MediaPipe / ML Kit Selfie Segmentation is
 * bundled. Uses the platform [FaceDetector]: soft ellipses covering head + upper torso.
 * Returns a grayscale bitmap (person ≈ white) sized to the request.
 */
object SubjectMask {
    private val cache = object : LruCache<String, Bitmap>(16 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    fun cached(file: File, time: MediaTime, width: Int, height: Int, isStill: Boolean): Bitmap? {
        if (width < 2 || height < 2) return null
        val bucket = time.ticks / (MediaTime.TIMESCALE / 4)
        val key = "${file.absolutePath}|$bucket|${width}x$height|$isStill"
        cache.get(key)?.let { return it }
        val frame = if (isStill) {
            Thumbnails.decodeImage(file, max(width, height).coerceAtLeast(256))
        } else {
            runCatching {
                MediaMetadataRetriever().use { r ->
                    r.setDataSource(file.absolutePath)
                    r.getScaledFrameAtTime(time.micros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 512, 512)
                }
            }.getOrNull()
        } ?: return null
        val mask = fromFaces(frame, width, height)
        frame.recycle()
        cache.put(key, mask)
        return mask
    }

    /** Soft person blobs from faces; if none, a soft centre prior so Cutout still does something. */
    fun fromFaces(frame: Bitmap, outW: Int, outH: Int): Bitmap {
        val w = (frame.width and 1.inv()).coerceAtLeast(2)
        val rgb = Bitmap.createScaledBitmap(frame, w, frame.height, true).copy(Bitmap.Config.RGB_565, false)
        val faces = arrayOfNulls<FaceDetector.Face>(8)
        val n = runCatching { FaceDetector(rgb.width, rgb.height, faces.size).findFaces(rgb, faces) }.getOrDefault(0)
        val blobs = ArrayList<Ellipse>()
        val sx = outW.toFloat() / rgb.width
        val sy = outH.toFloat() / rgb.height
        val mid = PointF()
        for (i in 0 until n) {
            val f = faces[i] ?: continue
            f.getMidPoint(mid)
            val eyes = f.eyesDistance()
            val rx = eyes * 1.6f * sx
            val ry = eyes * 2.8f * sy
            blobs += Ellipse(mid.x * sx, mid.y * sy + ry * 0.35f, rx, ry)
        }
        if (blobs.isEmpty()) {
            // Soft vertical subject prior (centre ~40% width).
            blobs += Ellipse(outW / 2f, outH * 0.42f, outW * 0.28f, outH * 0.42f)
        }
        if (rgb !== frame) rgb.recycle()
        return rasterize(outW, outH, blobs)
    }

    private data class Ellipse(val cx: Float, val cy: Float, val rx: Float, val ry: Float)

    /** Soft-edged grayscale mask (white = person) from one or more ellipses. */
    private fun rasterize(outW: Int, outH: Int, blobs: List<Ellipse>): Bitmap {
        val out = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val px = IntArray(outW * outH)
        for (y in 0 until outH) {
            for (x in 0 until outW) {
                var best = 0f
                for (b in blobs) {
                    val nx = (x + 0.5f - b.cx) / max(b.rx, 1f)
                    val ny = (y + 0.5f - b.cy) / max(b.ry, 1f)
                    val d = kotlin.math.sqrt(nx * nx + ny * ny)
                    // Soft falloff from 0.55 → 1.0 of the ellipse radius.
                    val m = Cutout.smoothstep(1f, 0.55f, d)
                    if (m > best) best = m
                }
                val v = (best * 255f).toInt().coerceIn(0, 255)
                px[y * outW + x] = Color.argb(255, v, v, v)
            }
        }
        out.setPixels(px, 0, outW, 0, 0, outW, outH)
        return out
    }

    @Synchronized
    fun clear() = cache.evictAll()
}

private inline fun <T> MediaMetadataRetriever.use(block: (MediaMetadataRetriever) -> T): T {
    try {
        return block(this)
    } finally {
        runCatching { release() }
    }
}
