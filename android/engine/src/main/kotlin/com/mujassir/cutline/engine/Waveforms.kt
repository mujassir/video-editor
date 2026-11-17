package com.mujassir.cutline.engine

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max

/**
 * Waveform peaks (IMPLEMENTATION §9.5): mono, `BUCKETS` buckets of peak absolute values over the
 * whole file, normalised to 0…1. Decodes with MediaCodec; the peaks don't depend on sample rate.
 */
object Waveforms {
    const val BUCKETS = 400

    fun peaks(file: File, durationUs: Long): FloatArray? = runCatching { decode(file, durationUs) }.getOrNull()

    private fun decode(file: File, durationUs: Long): FloatArray? {
        val extractor = MediaExtractor()
        extractor.setDataSource(file.absolutePath)
        val track = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: run { extractor.release(); return null }
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        val peaks = FloatArray(BUCKETS)
        val total = durationUs.coerceAtLeast(1)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        while (!outputDone) {
            if (!inputDone) {
                val i = codec.dequeueInputBuffer(10_000)
                if (i >= 0) {
                    val buf = codec.getInputBuffer(i)!!
                    val n = extractor.readSampleData(buf, 0)
                    if (n < 0) {
                        codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val o = codec.dequeueOutputBuffer(info, 10_000)
            when {
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                o >= 0 -> {
                    val out = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    val frames = out.remaining() / channels
                    val rate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE).toDouble()
                    for (f in 0 until frames) {
                        var v = 0f
                        for (c in 0 until channels) v = max(v, abs(out.get(f * channels + c) / 32768f))
                        val t = info.presentationTimeUs + (f * 1_000_000.0 / rate).toLong()
                        val b = ((t.toDouble() / total) * BUCKETS).toInt().coerceIn(0, BUCKETS - 1)
                        if (v > peaks[b]) peaks[b] = v
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
        }
        codec.stop(); codec.release(); extractor.release()
        val top = peaks.maxOrNull()?.takeIf { it > 0 } ?: return peaks
        for (i in peaks.indices) peaks[i] /= top
        return peaks
    }
}
