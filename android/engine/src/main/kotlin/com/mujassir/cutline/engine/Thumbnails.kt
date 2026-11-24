package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.util.LruCache
import androidx.exifinterface.media.ExifInterface
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max

/** Upright frames for the timeline, panels and the library (cached in memory). */
class Thumbnails(private val resolve: (MediaItem) -> File) {
    private val cache = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    private val retrievers = HashMap<String, MediaMetadataRetriever>()

    /** A frame of `item` at `time`, with its longer side about `maxSide` px. */
    @Synchronized
    fun frame(item: MediaItem, time: MediaTime, maxSide: Int = 160): Bitmap? {
        val bucket = time.ticks / (MediaTime.TIMESCALE / 4)        // quarter-second buckets
        val key = "${item.id}|$bucket|$maxSide"
        cache.get(key)?.let { return it }
        val bmp = when (item.kind) {
            MediaKind.PHOTO -> decodeImage(resolve(item), maxSide)
            MediaKind.VIDEO -> videoFrame(item, time, maxSide)
            MediaKind.AUDIO -> null
        } ?: return null
        cache.put(key, bmp)
        return bmp
    }

    private fun videoFrame(item: MediaItem, time: MediaTime, maxSide: Int): Bitmap? = runCatching {
        val path = resolve(item).absolutePath
        val r = retrievers.getOrPut(path) { MediaMetadataRetriever().also { it.setDataSource(path) } }
        val raw = r.getScaledFrameAtTime(time.micros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, maxSide, maxSide)
            ?: r.getFrameAtTime(time.micros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        raw?.let { scaled(upright(it, item.naturalSize.width > item.naturalSize.height, item.sourceQuarterTurns), maxSide) }
    }.getOrNull()

    @Synchronized
    fun release() {
        retrievers.values.forEach { runCatching { it.release() } }
        retrievers.clear()
        cache.evictAll()
    }

    companion object {
        /** Decodes an image upright (EXIF applied), longer side at most `maxSide`. */
        fun decodeImage(file: File, maxSide: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0) return null
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
            val bmp = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
            val turns = runCatching { MediaImporter.exifQuarterTurns(ExifInterface(file.absolutePath)) }.getOrDefault(0)
            val upright = if (turns == 0) bmp else Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(90f * turns) }, true)
            return scaled(upright, maxSide)
        }

        /**
         * Some devices return frames already upright, others raw: rotate only when the frame's
         * orientation doesn't match the upright size.
         */
        fun upright(b: Bitmap, uprightIsLandscape: Boolean, turns: Int): Bitmap {
            if (turns % 4 == 0 || (b.width > b.height) == uprightIsLandscape) return b
            return Bitmap.createBitmap(b, 0, 0, b.width, b.height, Matrix().apply { postRotate(90f * turns) }, true)
        }

        fun scaled(b: Bitmap, maxSide: Int): Bitmap {
            val longer = max(b.width, b.height)
            if (longer <= maxSide) return b
            val k = maxSide.toFloat() / longer
            return Bitmap.createScaledBitmap(b, (b.width * k).toInt().coerceAtLeast(1), (b.height * k).toInt().coerceAtLeast(1), true)
        }

        /** A still for a freeze frame (FRZ-1), upright, written as PNG once and reused. */
        fun freezeFrameFile(video: File, frameTime: MediaTime, cacheDir: File, uprightIsLandscape: Boolean, quarterTurns: Int): File? {
            cacheDir.mkdirs()
            val out = File(cacheDir, "freeze-${video.nameWithoutExtension}-${frameTime.ticks}.png")
            if (out.exists()) return out
            val r = MediaMetadataRetriever()
            return try {
                r.setDataSource(video.absolutePath)
                val raw = r.getFrameAtTime(frameTime.micros, MediaMetadataRetriever.OPTION_CLOSEST) ?: return null
                val upright = upright(raw, uprightIsLandscape, quarterTurns)
                FileOutputStream(out).use { upright.compress(Bitmap.CompressFormat.PNG, 100, it) }
                out
            } catch (_: Exception) {
                null
            } finally {
                r.release()
            }
        }
    }
}
