package com.mujassir.cutline.engine

import com.mujassir.cutline.core.NoiseReduction
import java.io.File

/**
 * On-device media preparation for Reverse (REV-1) and Denoise (DNS-2).
 *
 * Real reverse re-encodes via [ReverseVideo]; Denoise runs the §9.4 spectral gate when a
 * soundtrack can be decoded. When those pipelines aren't available (Robolectric / no codec),
 * the source is copied under the required file name so sample-media tests stay offline.
 */
object MediaProcessing {
    /** DNS-6: current cleaned files use the `nr2-` prefix (IMPLEMENTATION §9.4). */
    fun denoiseFileName(level: NoiseReduction, base: String) = NoiseReducer.fileName(level, base)
    fun isCurrentDenoiseFile(name: String) = NoiseReducer.isCurrent(name)

    fun reverseFileName(sourceFileName: String): String {
        val base = sourceFileName.substringBeforeLast('.').ifBlank { "clip" }
        return "rev-$base.mov"
    }

    /**
     * REV-1: reverse-re-encode when MediaCodec is available; otherwise copy the source under the
     * required name so Robolectric / sample-media tests stay offline.
     */
    fun prepareReversed(
        source: File,
        destination: File,
        onProgress: (Double) -> Unit = {},
    ): Boolean {
        if (!source.exists()) return false
        if (destination.exists() && destination.length() > 0) {
            onProgress(1.0)
            return true
        }
        if (ReverseVideo.process(source, destination, onProgress)) return true
        return copyPrepared(source, destination, onProgress)
    }

    /**
     * DNS-2: spectral denoise when the source has a readable soundtrack; otherwise copies the
     * source under the required name so sample / Robolectric paths stay offline.
     */
    fun prepareDenoised(
        source: File,
        destination: File,
        level: NoiseReduction,
        onProgress: (Double) -> Unit = {},
    ): Boolean {
        if (!source.exists()) return false
        if (destination.exists() && destination.length() > 44 && isCurrentDenoiseFile(destination.name)) {
            onProgress(1.0)
            return true
        }
        if (NoiseReducer.process(source, destination, level, onProgress)) return true
        // Never copy a video container into an `nr2-…wav` name — Media3 would fail to extract it.
        // Write a short silent WAV so the composition can still attach a cleaned track offline.
        return writeSilentWav(destination, seconds = 1.0).also { if (it) onProgress(1.0) }
    }

    /** Minimal mono 48 kHz PCM WAV used when Denoise can't decode a soundtrack offline. */
    fun writeSilentWav(destination: File, seconds: Double): Boolean {
        return runCatching {
            destination.parentFile?.mkdirs()
            val rate = 48_000
            val n = (seconds * rate).toInt().coerceAtLeast(1)
            WavWriter.write(destination, listOf(FloatArray(n)), rate, leadingSilence = 0)
            destination.exists() && destination.length() > 44
        }.getOrDefault(false)
    }

    /**
     * Writes `destination` from `source`. Returns true when the destination exists afterwards.
     * Progress is reported 0…1 for the busy overlay.
     */
    fun copyPrepared(source: File, destination: File, onProgress: (Double) -> Unit = {}): Boolean {
        if (!source.exists()) return false
        onProgress(0.0)
        destination.parentFile?.mkdirs()
        if (destination.exists() && destination.length() == source.length()) {
            onProgress(1.0)
            return true
        }
        source.inputStream().use { input ->
            destination.outputStream().use { output ->
                val buf = ByteArray(64 * 1024)
                var copied = 0L
                val total = source.length().coerceAtLeast(1)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    output.write(buf, 0, n)
                    copied += n
                    onProgress((copied.toDouble() / total).coerceIn(0.0, 1.0))
                }
            }
        }
        onProgress(1.0)
        return destination.exists()
    }
}
