package com.mujassir.cutline.engine

import com.mujassir.cutline.core.NoiseReduction
import java.io.File

/**
 * On-device media preparation for Reverse (REV-1) and Denoise (DNS-2).
 *
 * A real reverse re-encodes frames backwards; Denoise cleans the soundtrack. Until device
 * pipelines land, both prepare by copying the source under the required file name so the
 * composition can switch, and Robolectric / sample-media tests stay offline.
 */
object MediaProcessing {
    /** DNS-6: current cleaned files use the `nr2-` prefix (IMPLEMENTATION §9.4). */
    fun denoiseFileName(level: NoiseReduction, base: String) = "nr2-${level.raw}-$base.m4a"
    fun isCurrentDenoiseFile(name: String) = name.startsWith("nr2-")

    fun reverseFileName(sourceFileName: String): String {
        val base = sourceFileName.substringBeforeLast('.').ifBlank { "clip" }
        return "rev-$base.mov"
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
