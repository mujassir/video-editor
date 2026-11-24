package com.mujassir.cutline.engine

import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.duration

/** Export resolution (EXP). Kept free of Media3 so the export form can compose in JVM UI tests. */
enum class ExportResolution(val title: String, val shortEdge: Int, val baseBitsPerSecond: Double) {
    P720("720p", 720, 8e6), P1080("1080p", 1080, 16e6), P2160("4K", 2160, 45e6)
}

/** Size estimate and file naming (IMPLEMENTATION §11). */
object ExportEstimate {
    /** `<project name>.mp4` without / \ : ? % * | " < >, trimmed; "Cut & Weld Video" when empty. */
    fun fileName(name: String): String {
        val clean = name.filterNot { it in "/\\:?%*|\"<>" }.trim()
        return (clean.ifEmpty { "Cut & Weld Video" }) + ".mp4"
    }

    fun fpsFactor(fps: Int) = when {
        fps >= 60 -> 1.5
        fps <= 24 -> 0.85
        else -> 1.0
    }

    fun targetBitrate(r: ExportResolution, fps: Int, hevc: Boolean) =
        r.baseBitsPerSecond * fpsFactor(fps) * (if (hevc) 0.55 else 1.0)

    /** EXP estimate: (base × fps × codec + 256 000) × seconds ÷ 8 bytes. */
    fun estimatedBytes(project: Project, r: ExportResolution, fps: Int, hevc: Boolean): Long =
        ((targetBitrate(r, fps, hevc) + 256_000) * project.duration.seconds / 8).toLong()
}
