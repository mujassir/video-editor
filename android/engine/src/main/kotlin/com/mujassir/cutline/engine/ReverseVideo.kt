package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * REV-1: reverse a video (picture only, no soundtrack) by re-encoding frames newest→oldest.
 *
 * Matches iOS `UtilityMedia.makeReversedVideo`: 1 s decode windows from the end, reverse each
 * window, write with `pts = max(0, total − t − frameDuration)`. Robolectric / hosts without a
 * working encoder fall back via [MediaProcessing.prepareReversed].
 */
object ReverseVideo {
    const val WINDOW_SECONDS = 1.0

    /** Presentation time in the reversed file for a source timestamp `t` (seconds). */
    fun reversedPresentationTime(sourceTime: Double, total: Double, frameDuration: Double): Double =
        max(0.0, total - sourceTime - frameDuration)

    /**
     * Decode windows newest-first as `[start, end)` covering `[0, total)`.
     * Mirrors the iOS loop (`windowEnd` walks down by [WINDOW_SECONDS]).
     */
    fun windows(total: Double, window: Double = WINDOW_SECONDS): List<Pair<Double, Double>> {
        if (total <= 0.0001) return emptyList()
        val out = ArrayList<Pair<Double, Double>>()
        var windowEnd = total
        while (windowEnd > 0.0001) {
            val windowStart = max(0.0, windowEnd - window)
            out += windowStart to windowEnd
            windowEnd = windowStart
        }
        return out
    }

    /**
     * Sample times inside a window at [frameDuration] steps (source times), then newest first.
     */
    fun sampleTimesInWindow(windowStart: Double, windowEnd: Double, frameDuration: Double): List<Double> {
        if (frameDuration <= 0) return emptyList()
        val times = ArrayList<Double>()
        var t = windowStart
        while (t < windowEnd - 0.0001) {
            times += t
            t += frameDuration
        }
        return times.asReversed()
    }

    /**
     * Writes a reversed, video-only file to [destination] (MPEG-4 container; name may end in `.mov`
     * for project-file parity with iOS). Returns false when probing or encoding fails.
     */
    fun process(source: File, destination: File, onProgress: ((Double) -> Unit)? = null): Boolean {
        if (!source.exists()) return false
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(source.absolutePath)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                ?: return false
            val total = durationMs / 1000.0
            if (total <= 0.05) return false
            var width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                ?: return false
            var height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                ?: return false
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation == 90 || rotation == 270) {
                val tmp = width; width = height; height = tmp
            }
            width = (width and 1.inv()).coerceAtLeast(2)
            height = (height and 1.inv()).coerceAtLeast(2)
            val fps = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                ?.toFloatOrNull()?.takeIf { it > 1f } ?: 30f
            val frameDuration = 1.0 / fps
            val bitrate = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()
                ?: (width * height * 4).coerceIn(1_000_000, 8_000_000)

            destination.parentFile?.mkdirs()
            if (destination.exists()) destination.delete()

            encodeReversed(
                retriever, destination, width, height, total, frameDuration,
                fps.toInt().coerceIn(1, 60), bitrate, onProgress,
            )
        } catch (_: Exception) {
            false
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun encodeReversed(
        retriever: MediaMetadataRetriever,
        destination: File,
        width: Int,
        height: Int,
        total: Double,
        frameDuration: Double,
        fps: Int,
        bitrate: Int,
        onProgress: ((Double) -> Unit)?,
    ): Boolean {
        val mime = MediaFormat.MIMETYPE_VIDEO_AVC
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val encoder = try {
            MediaCodec.createEncoderByType(mime).also {
                it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                it.start()
            }
        } catch (_: Exception) {
            return false
        }
        val muxer = MediaMuxer(destination.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var muxerStarted = false
        val info = MediaCodec.BufferInfo()
        var lastWritten = -1.0
        val yuv = ByteArray(width * height * 3 / 2)
        fun drain(untilEos: Boolean = false): Boolean {
            while (true) {
                val outIndex = encoder.dequeueOutputBuffer(info, if (untilEos) 20_000 else 2_000)
                when {
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> return false
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        if (!muxerStarted) {
                            track = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                    }
                    outIndex >= 0 -> {
                        val outBuf = encoder.getOutputBuffer(outIndex)
                        if (outBuf != null && info.size > 0 && muxerStarted && track >= 0) {
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            muxer.writeSampleData(track, outBuf, info)
                        }
                        val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        encoder.releaseOutputBuffer(outIndex, false)
                        if (eos) return true
                    }
                }
            }
        }
        try {
            val ranges = windows(total)
            for ((index, range) in ranges.withIndex()) {
                val (windowStart, windowEnd) = range
                for (sourceT in sampleTimesInWindow(windowStart, windowEnd, frameDuration)) {
                    val ptsSec = reversedPresentationTime(sourceT, total, frameDuration)
                    if (ptsSec <= lastWritten + 0.0005) continue
                    lastWritten = ptsSec
                    val bmp = retriever.getFrameAtTime(
                        (sourceT * 1_000_000).roundToLong(),
                        MediaMetadataRetriever.OPTION_CLOSEST,
                    ) ?: continue
                    try {
                        rgbaToNV12(bmp, yuv, width, height)
                    } finally {
                        bmp.recycle()
                    }
                    var inputIndex = encoder.dequeueInputBuffer(50_000)
                    var spins = 0
                    while (inputIndex < 0 && spins++ < 40) {
                        drain()
                        inputIndex = encoder.dequeueInputBuffer(50_000)
                    }
                    if (inputIndex < 0) continue
                    val inBuf = encoder.getInputBuffer(inputIndex) ?: continue
                    inBuf.clear()
                    inBuf.put(yuv)
                    encoder.queueInputBuffer(inputIndex, 0, yuv.size, (ptsSec * 1_000_000).roundToLong(), 0)
                    drain()
                }
                onProgress?.invoke(min(1.0, (index + 1).toDouble() / ranges.size.coerceAtLeast(1)))
            }
            val eos = encoder.dequeueInputBuffer(50_000)
            if (eos >= 0) encoder.queueInputBuffer(eos, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            var guard = 0
            while (guard++ < 200 && !drain(untilEos = true)) { /* wait for EOS */ }
            if (muxerStarted) muxer.stop()
            muxer.release()
            encoder.stop()
            encoder.release()
            onProgress?.invoke(1.0)
            return destination.exists() && destination.length() > 0 && lastWritten >= 0
        } catch (_: Exception) {
            runCatching { muxer.release() }
            runCatching { encoder.stop(); encoder.release() }
            destination.delete()
            return false
        }
    }

    /** ARGB bitmap → NV12 (YUV420 semi-planar) for AVC encoders. */
    fun rgbaToNV12(bitmap: Bitmap, out: ByteArray, width: Int, height: Int) {
        val pixels = IntArray(width * height)
        val src = if (bitmap.width == width && bitmap.height == height) bitmap
        else Bitmap.createScaledBitmap(bitmap, width, height, true)
        src.getPixels(pixels, 0, width, 0, 0, width, height)
        var yIndex = 0
        var uvIndex = width * height
        for (j in 0 until height) {
            for (i in 0 until width) {
                val p = pixels[j * width + i]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                out[yIndex++] = y.coerceIn(0, 255).toByte()
                if (j % 2 == 0 && i % 2 == 0) {
                    val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    out[uvIndex++] = u.coerceIn(0, 255).toByte()
                    out[uvIndex++] = v.coerceIn(0, 255).toByte()
                }
            }
        }
        if (src !== bitmap) src.recycle()
    }
}
