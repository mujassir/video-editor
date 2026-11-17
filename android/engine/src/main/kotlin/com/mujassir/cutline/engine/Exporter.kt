package com.mujassir.cutline.engine

import android.content.Context
import android.media.MediaCodecList
import android.os.Build
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
import java.io.File
import java.nio.file.Files

/** Export (IMPLEMENTATION §11): Media3 Transformer. Estimates live in [ExportEstimate]. */
@UnstableApi
class Exporter(private val context: Context, private val builder: CompositionBuilder, private val toggles: RenderToggles) {
    sealed interface State {
        data class Running(val progress: Double) : State
        data class Done(val file: File) : State
        data class Failed(val message: String) : State
    }

    private var transformer: Transformer? = null
    private val main = Handler(Looper.getMainLooper())

    fun start(project: Project, resolution: ExportResolution, fps: Int, wantHevc: Boolean, onState: (State) -> Unit) {
        val built = builder.build(project.copy(frameRate = fps), resolution.shortEdge, preview = false)
        val dir = Files.createTempDirectory(context.cacheDir.toPath(), "export").toFile()
        val out = File(dir, ExportEstimate.fileName(project.name))
        val hevc = wantHevc && supportsHevc()
        val bitrate = ExportEstimate.targetBitrate(resolution, fps, hevc)
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

    companion object {
        // Compatibility wrappers so call sites can keep using Exporter.* for estimates.
        fun fileName(name: String) = ExportEstimate.fileName(name)
        fun fpsFactor(fps: Int) = ExportEstimate.fpsFactor(fps)
        fun targetBitrate(r: ExportResolution, fps: Int, hevc: Boolean) = ExportEstimate.targetBitrate(r, fps, hevc)
        fun estimatedBytes(project: Project, r: ExportResolution, fps: Int, hevc: Boolean) =
            ExportEstimate.estimatedBytes(project, r, fps, hevc)

        fun supportsHevc(): Boolean {
            // Robolectric has no real codecs; MediaCodecList can hang and freeze the export screen.
            if (Build.FINGERPRINT.contains("robolectric", ignoreCase = true)) return false
            return runCatching {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                    info.isEncoder && info.supportedTypes.any { it.equals(MimeTypes.VIDEO_H265, ignoreCase = true) }
                }
            }.getOrDefault(false)
        }
    }
}
