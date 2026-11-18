package com.mujassir.cutline.engine

import com.mujassir.cutline.core.NoiseReduction
import java.io.File

/**
 * On-device media preparation for Reverse (REV-1) and Denoise (DNS-2).
 *
 * Denoise runs the §9.4 spectral gate when a soundtrack can be decoded; otherwise (and for
 * Reverse until the encoder lands) the source is copied under the required file name so
 * Robolectric / sample-media tests stay offline.
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
        return copyPrepared(source, destination, onProgress)
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
