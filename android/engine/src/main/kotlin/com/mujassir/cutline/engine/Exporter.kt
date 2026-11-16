package com.mujassir.cutline.engine

import android.content.Context
import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.duration
import java.io.File
import java.nio.file.Files

/** Export resolution (EXP). */
enum class ExportResolution(val title: String, val shortEdge: Int, val baseBitsPerSecond: Double) {
    P720("720p", 720, 8e6), P1080("1080p", 1080, 16e6), P2160("4K", 2160, 45e6)
}

/** Export (IMPLEMENTATION §11): size estimate, file naming, Media3 Transformer. */
@UnstableApi
class Exporter(private val context: Context, private val builder: CompositionBuilder, private val toggles: RenderToggles) {
    sealed interface State {
        data class Running(val progress: Double) : State
        data class Done(val file: File) : State
        data class Failed(val message: String) : State
    }

    private var transformer: Transformer? = null
    private val main = Handler(Looper.getMainLooper())

    fun start(project: Project, resolution: ResolutionChoice, onState: (State) -> Unit) {
        val built = builder.build(project, resolution.resolution.shortEdge, preview = false)
        val dir = Files.createTempDirectory(context.cacheDir.toPath(), "export").toFile()
        val out = File(dir, fileName(project.name))
        val hevc = supportsHevc()
        val bitrate = targetBitrate(resolution.resolution, project.frameRate, hevc)
        val encoder = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate.toInt()).build())
            .build()
        toggles.animate.set(true)
        val t = Transformer.Builder(context)
            .setVideoMimeType(if (hevc) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
            .setEncoderFactory(encoder)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    transformer = null
                    onState(State.Done(out))
                }

                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                    transformer = null
                    onState(State.Failed(exportException.message ?: "Export failed"))
                }
            })
            .build()
        transformer = t
        t.start(built.composition, out.absolutePath)
        val holder = ProgressHolder()
        val poll = object : Runnable {
            override fun run() {
                val tr = transformer ?: return
                if (tr.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) onState(State.Running(holder.progress / 100.0))
                main.postDelayed(this, 200)
            }
        }
        main.post(poll)
    }

    fun cancel() {
        transformer?.cancel()
        transformer = null
    }

    data class ResolutionChoice(val resolution: ExportResolution)

    companion object {
        /** `<project name>.mp4` without / \ : ? % * | " < >, trimmed; "Cutline Video" when empty. */
        fun fileName(name: String): String {
            val clean = name.filterNot { it in "/\\:?%*|\"<>" }.trim()
            return (clean.ifEmpty { "Cutline Video" }) + ".mp4"
        }

        fun fpsFactor(fps: Int) = when { fps >= 60 -> 1.5; fps <= 24 -> 0.85; else -> 1.0 }

        fun targetBitrate(r: ExportResolution, fps: Int, hevc: Boolean) = r.baseBitsPerSecond * fpsFactor(fps) * (if (hevc) 0.55 else 1.0)

        /** EXP estimate: (base × fps × codec + 256 000) × seconds ÷ 8 bytes. */
        fun estimatedBytes(project: Project, r: ExportResolution, hevc: Boolean): Long =
            ((targetBitrate(r, project.frameRate, hevc) + 256_000) * project.duration.seconds / 8).toLong()

        fun supportsHevc(): Boolean = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                info.isEncoder && info.supportedTypes.any { it.equals(MimeTypes.VIDEO_H265, ignoreCase = true) }
            }
        }.getOrDefault(false)

    }
}
