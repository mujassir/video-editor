package com.mujassir.cutline.engine

import com.mujassir.cutline.core.NoiseReduction
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Spectral noise gate (DNS, IMPLEMENTATION §9.4).
 *
 * Pure Float32 DSP so JVM unit tests can lock the required hiss / tone results without a device.
 * [process] decodes with [AudioDecoder] when available and writes a WAV (lossless timing).
 */
object NoiseReducer {
    const val FRAME_SIZE = 2048
    const val HOP = 512
    private const val SAMPLE_RATE = 48_000
    private val silentEnergy = FRAME_SIZE * 1e-10f

    data class Settings(val oversubtraction: Float, val floor: Float)

    fun settings(level: NoiseReduction) = when (level) {
        NoiseReduction.LOW -> Settings(1.5f, 0.30f)
        NoiseReduction.MEDIUM -> Settings(2.2f, 0.15f)
        NoiseReduction.HIGH -> Settings(3.0f, 0.06f)
    }

    /** DNS-3 / DNS-6: Android writes WAV; only `nr2-` names are reused. */
    fun fileName(level: NoiseReduction, base: String) = "nr2-${level.raw}-$base.wav"
    fun isCurrent(fileName: String) = fileName.startsWith("nr2-")

    /**
     * Frames for the noise fingerprint: quietest 10% of frames near the real noise floor
     * (skips padding and digital silence — DNS-6).
     */
    fun noiseFrames(energies: FloatArray, length: Int): IntArray {
        val first = FRAME_SIZE / HOP
        val last = min(energies.lastIndex, length / HOP)
        val inside = if (first <= last) (first..last).toList() else energies.indices.toList()
        val audible = inside.filter { energies[it] > silentEnergy }
        if (audible.isEmpty()) return energies.indices.toList().toIntArray()
        val framesPerSecond = SAMPLE_RATE / HOP
        val minima = ArrayList<Float>()
        var second = audible[0] / framesPerSecond
        var lowest = Float.POSITIVE_INFINITY
        for (f in audible) {
            if (f / framesPerSecond != second) {
                minima += lowest
                second = f / framesPerSecond
                lowest = Float.POSITIVE_INFINITY
            }
            lowest = min(lowest, energies[f])
        }
        minima += lowest
        val floor = minima.sorted()[minima.size / 2]
        var usable = audible.filter { energies[it] >= floor * 0.1f }
        if (usable.size < 5) usable = audible
        val take = max(5, usable.size / 10)
        return usable.sortedBy { energies[it] }.take(take).toIntArray()
    }

    /** Pure DSP: one array per channel in, the same shape out. */
    fun reduce(
        channels: List<FloatArray>,
        level: NoiseReduction,
        onProgress: ((Double) -> Unit)? = null,
    ): List<FloatArray> {
        val length = channels.firstOrNull()?.size ?: return channels
        if (length <= FRAME_SIZE) return channels
        val s = settings(level)
        val n = FRAME_SIZE
        val half = n / 2
        val window = hann(n)
        val padFront = n
        val padEnd = n + HOP
        val padded = channels.map { ch ->
            FloatArray(padFront + ch.size + padEnd).also { out ->
                System.arraycopy(ch, 0, out, padFront, ch.size)
            }
        }
        val mono = if (padded.size == 1) padded[0] else {
            FloatArray(padded[0].size).also { m ->
                val inv = 1f / padded.size
                for (i in m.indices) {
                    var sum = 0f
                    for (c in padded) sum += c[i]
                    m[i] = sum * inv
                }
            }
        }
        val frameCount = (mono.size - n) / HOP + 1
        val energies = FloatArray(frameCount)
        for (f in 0 until frameCount) {
            var e = 0f
            val start = f * HOP
            for (i in 0 until n) {
                val x = mono[start + i]
                e += x * x
            }
            energies[f] = e
        }
        val quiet = noiseFrames(energies, length)
        val noise = FloatArray(half + 1)
        val mags = FloatArray(half + 1)
        val re = FloatArray(half + 1)
        val im = FloatArray(half + 1)
        for (f in quiet) {
            spectrum(mono, f * HOP, window, re, im, mags)
            for (k in 0..half) noise[k] += mags[k]
        }
        val invQ = 1f / quiet.size
        for (k in 0..half) noise[k] *= invQ

        val outputs = padded.map { FloatArray(it.size) }
        val gains = FloatArray(half + 1) { 1f }
        val previous = FloatArray(half + 1) { 1f }
        val smoothed = FloatArray(half + 1)
        val cre = FloatArray(half + 1)
        val cim = FloatArray(half + 1)
        val frame = FloatArray(n)
        for (f in 0 until frameCount) {
            val start = f * HOP
            spectrum(mono, start, window, re, im, mags)
            for (k in 0..half) {
                val m = mags[k]
                var g = if (m > 0f) 1f - s.oversubtraction * noise[k] / m else 0f
                g = max(s.floor, min(1f, g))
                g = if (g >= previous[k]) g else previous[k] * 0.6f + g * 0.4f
                gains[k] = g
            }
            System.arraycopy(gains, 0, previous, 0, gains.size)
            smoothed[0] = gains[0]
            smoothed[half] = gains[half]
            for (k in 1 until half) {
                smoothed[k] = (gains[k - 1] + 2f * gains[k] + gains[k + 1]) / 4f
            }
            for (c in padded.indices) {
                for (i in 0 until n) frame[i] = padded[c][start + i] * window[i]
                RealFft.forward(frame, cre, cim)
                cre[0] *= smoothed[0]
                cim[0] = 0f
                cre[half] *= smoothed[half]
                cim[half] = 0f
                for (k in 1 until half) {
                    cre[k] *= smoothed[k]
                    cim[k] *= smoothed[k]
                }
                RealFft.inverse(cre, cim, frame)
                for (i in 0 until n) {
                    // Synthesis Hann + OLA. Complex FFT round-trip scales by N; Hann² @ 75% ≈ 1.5.
                    outputs[c][start + i] += frame[i] * window[i] / (n * 1.5f)
                }
            }
            if (onProgress != null && f % 256 == 0) onProgress(f.toDouble() / frameCount)
        }
        onProgress?.invoke(1.0)
        return outputs.map { out -> out.copyOfRange(padFront, padFront + length) }
    }

    /**
     * Decodes [source] audio to 48 kHz Float32 (≤2 ch), reduces noise, writes a WAV to [destination].
     * Returns false when there is no readable audio track.
     */
    fun process(source: File, destination: File, level: NoiseReduction, onProgress: ((Double) -> Unit)? = null): Boolean {
        val decoded = AudioDecoder.decodeToFloat(source, SAMPLE_RATE, maxChannels = 2) ?: return false
        val cleaned = reduce(decoded.channels, level, onProgress)
        val lead = max(0, (decoded.offsetSeconds * SAMPLE_RATE).toInt())
        WavWriter.write(destination, cleaned, SAMPLE_RATE, lead)
        return destination.exists()
    }

    private fun spectrum(
        signal: FloatArray,
        start: Int,
        window: FloatArray,
        re: FloatArray,
        im: FloatArray,
        mags: FloatArray,
    ) {
        val n = window.size
        val frame = FloatArray(n)
        for (i in 0 until n) frame[i] = signal[start + i] * window[i]
        RealFft.forward(frame, re, im)
        mags[0] = abs(re[0])
        mags[n / 2] = abs(re[n / 2])
        for (k in 1 until n / 2) mags[k] = sqrt(re[k] * re[k] + im[k] * im[k])
    }

    private fun hann(n: Int): FloatArray {
        val w = FloatArray(n)
        val scale = 2.0 * PI / n
        for (i in 0 until n) w[i] = (0.5 - 0.5 * cos(scale * i)).toFloat()
        return w
    }
}

/** Radix-2 real FFT helpers (bins 0…N/2). Forward/inverse are unnormalized (round-trip × N). */
internal object RealFft {
    fun forward(frame: FloatArray, reOut: FloatArray, imOut: FloatArray) {
        val n = frame.size
        require(n and (n - 1) == 0)
        val re = FloatArray(n)
        val im = FloatArray(n)
        System.arraycopy(frame, 0, re, 0, n)
        fft(re, im, inverse = false)
        val half = n / 2
        for (k in 0..half) {
            reOut[k] = re[k]
            imOut[k] = im[k]
        }
    }

    fun inverse(reIn: FloatArray, imIn: FloatArray, frameOut: FloatArray) {
        val n = frameOut.size
        val half = n / 2
        val re = FloatArray(n)
        val im = FloatArray(n)
        re[0] = reIn[0]
        im[0] = 0f
        re[half] = reIn[half]
        im[half] = 0f
        for (k in 1 until half) {
            re[k] = reIn[k]
            im[k] = imIn[k]
            re[n - k] = reIn[k]
            im[n - k] = -imIn[k]
        }
        fft(re, im, inverse = true)
        System.arraycopy(re, 0, frameOut, 0, n)
    }

    private fun fft(re: FloatArray, im: FloatArray, inverse: Boolean) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j xor bit
            if (i < j) {
                val tr = re[i]; re[i] = re[j]; re[j] = tr
                val ti = im[i]; im[i] = im[j]; im[j] = ti
            }
        }
        var len = 2
        val sign = if (inverse) 1.0 else -1.0
        while (len <= n) {
            val half = len / 2
            val ang = sign * 2.0 * PI / len
            val wlenRe = cos(ang)
            val wlenIm = sin(ang)
            var i = 0
            while (i < n) {
                var wRe = 1.0
                var wIm = 0.0
                for (k in 0 until half) {
                    val uRe = re[i + k]
                    val uIm = im[i + k]
                    val vRe = (re[i + k + half] * wRe - im[i + k + half] * wIm).toFloat()
                    val vIm = (re[i + k + half] * wIm + im[i + k + half] * wRe).toFloat()
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + half] = uRe - vRe
                    im[i + k + half] = uIm - vIm
                    val nextWRe = wRe * wlenRe - wIm * wlenIm
                    wIm = wRe * wlenIm + wIm * wlenRe
                    wRe = nextWRe
                }
                i += len
            }
            len = len shl 1
        }
    }
}

/** Decode a media file's audio to Float32 channels at a target sample rate. */
object AudioDecoder {
    data class Decoded(val channels: List<FloatArray>, val offsetSeconds: Double)

    fun decodeToFloat(source: File, sampleRate: Int, maxChannels: Int): Decoded? {
        if (!source.exists()) return null
        return runCatching {
            val extractor = android.media.MediaExtractor()
            extractor.setDataSource(source.absolutePath)
            val track = (0 until extractor.trackCount).firstOrNull { i ->
                extractor.getTrackFormat(i).getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: run { extractor.release(); return null }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(android.media.MediaFormat.KEY_MIME) ?: return null.also { extractor.release() }
            val decoder = android.media.MediaCodec.createDecoderByType(mime)
            decoder.configure(format, null, null, 0)
            decoder.start()
            val srcRate = if (format.containsKey(android.media.MediaFormat.KEY_SAMPLE_RATE))
                format.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE) else sampleRate
            val srcCh = if (format.containsKey(android.media.MediaFormat.KEY_CHANNEL_COUNT))
                format.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT) else 1
            val channels = min(max(srcCh, 1), maxChannels)
            val pcm = ArrayList<Float>()
            var offsetUs: Long? = null
            val info = android.media.MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = decoder.getInputBuffer(inIndex)!!
                        val sample = extractor.readSampleData(buf, 0)
                        if (sample < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            if (offsetUs == null) offsetUs = extractor.sampleTime
                            decoder.queueInputBuffer(inIndex, 0, sample, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = decoder.dequeueOutputBuffer(info, 10_000)
                if (outIndex >= 0) {
                    val out = decoder.getOutputBuffer(outIndex)!!
                    if (info.size > 0) {
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        val shorts = info.size / 2
                        val tmp = ShortArray(shorts)
                        out.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(tmp)
                        for (s in tmp) pcm += s / 32768f
                    }
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
            decoder.stop(); decoder.release(); extractor.release()
            if (pcm.isEmpty()) return null
            val frames = pcm.size / srcCh
            val planar = List(channels) { c ->
                FloatArray(frames) { i -> pcm[i * srcCh + min(c, srcCh - 1)] }
            }
            val resampled = if (srcRate == sampleRate) planar else planar.map { resample(it, srcRate, sampleRate) }
            Decoded(resampled, (offsetUs ?: 0L) / 1_000_000.0)
        }.getOrNull()
    }

    private fun resample(input: FloatArray, from: Int, to: Int): FloatArray {
        if (from == to) return input
        val outLen = max(1, (input.size.toLong() * to / from).toInt())
        val out = FloatArray(outLen)
        val ratio = from.toDouble() / to
        for (i in 0 until outLen) {
            val src = i * ratio
            val i0 = src.toInt().coerceIn(0, input.lastIndex)
            val i1 = min(i0 + 1, input.lastIndex)
            val t = (src - i0).toFloat()
            out[i] = input[i0] * (1 - t) + input[i1] * t
        }
        return out
    }
}

/** Little-endian PCM WAV writer (IMPLEMENTATION §9.4 lossless path on Android). */
object WavWriter {
    fun write(destination: File, channels: List<FloatArray>, sampleRate: Int, leadingSilence: Int) {
        destination.parentFile?.mkdirs()
        val ch = channels.size.coerceAtLeast(1)
        val frames = (channels.firstOrNull()?.size ?: 0) + leadingSilence
        val dataBytes = frames * ch * 2
        RandomAccessFile(destination, "rw").use { raf ->
            raf.setLength(0)
            raf.writeBytes("RIFF")
            raf.writeIntLE(36 + dataBytes)
            raf.writeBytes("WAVE")
            raf.writeBytes("fmt ")
            raf.writeIntLE(16)
            raf.writeShortLE(1) // PCM
            raf.writeShortLE(ch)
            raf.writeIntLE(sampleRate)
            raf.writeIntLE(sampleRate * ch * 2)
            raf.writeShortLE(ch * 2)
            raf.writeShortLE(16)
            raf.writeBytes("data")
            raf.writeIntLE(dataBytes)
            val silence = ShortArray(ch)
            repeat(leadingSilence) {
                for (s in silence) raf.writeShortLE(s.toInt())
            }
            val length = channels.firstOrNull()?.size ?: 0
            for (i in 0 until length) {
                for (c in 0 until ch) {
                    val sample = channels[c][i].coerceIn(-1f, 1f)
                    val s = (sample * 32767f).toInt().coerceIn(-32768, 32767)
                    raf.writeShortLE(s)
                }
            }
        }
    }

    private fun RandomAccessFile.writeIntLE(v: Int) {
        write(byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte(),
            ((v shr 16) and 0xff).toByte(), ((v shr 24) and 0xff).toByte()))
    }

    private fun RandomAccessFile.writeShortLE(v: Int) {
        write(byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte()))
    }

    private fun RandomAccessFile.writeBytes(s: String) = write(s.toByteArray(Charsets.US_ASCII))
}
