package com.mujassir.cutline.app.editor

import android.content.Context
import androidx.media3.common.util.UnstableApi
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.engine.CompositionBuilder
import com.mujassir.cutline.engine.ExportResolution
import com.mujassir.cutline.engine.Exporter
import java.io.File

/** Callback states for [startMedia3Export], mirroring [Exporter.State] without loading Media3 in the form. */
sealed interface ExportRunState {
    data class Running(val progress: Double) : ExportRunState
    data class Done(val file: File) : ExportRunState
    data class Failed(val message: String) : ExportRunState
}

/** Starts a Media3 export. Kept in its own file so ExportScreen can compose without class-loading Transformer. */
@OptIn(UnstableApi::class)
fun startMedia3Export(
    context: Context,
    model: EditorModel,
    project: Project,
    resolution: ExportResolution,
    fps: Int,
    hevc: Boolean,
    onState: (ExportRunState) -> Unit,
) {
    val exporter = Exporter(context, CompositionBuilder(model.store, model.player.toggles), model.player.toggles)
    exporter.start(project, resolution, fps, hevc) { s ->
        onState(
            when (s) {
                is Exporter.State.Running -> ExportRunState.Running(s.progress)
                is Exporter.State.Done -> ExportRunState.Done(s.file)
                is Exporter.State.Failed -> ExportRunState.Failed(s.message)
            },
        )
    }
}
