package com.mujassir.cutline.app

import android.content.pm.ActivityInfo
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.media3.common.util.UnstableApi
import com.mujassir.cutline.app.editor.CompositionPreviewPlayer
import com.mujassir.cutline.app.editor.EditorModel
import com.mujassir.cutline.app.editor.EditorScreen
import com.mujassir.cutline.app.library.LibraryModel
import com.mujassir.cutline.app.library.LibraryScreen
import com.mujassir.cutline.app.ui.CutlineTheme
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.RecentAudioStore
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // LAY-4: phones are portrait only; tablets (smallest width ≥ 600 dp) use any orientation.
        requestedOrientation = if (resources.configuration.smallestScreenWidthDp < 600) ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        enableEdgeToEdge()
        val sample = intent?.getBooleanExtra("sampleMedia", false) == true
        setContent { CutlineTheme { CutlineApp(sampleMedia = sample) } }
    }
}

/** App root: the library, or the editor for one project (RootView on iOS). */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
fun CutlineApp(sampleMedia: Boolean = false, rootDir: File? = null, playerFactory: ((ProjectStore) -> com.mujassir.cutline.app.editor.PreviewPlayer)? = null) {
    val context = LocalContext.current
    val base = rootDir ?: context.filesDir
    val store = remember { ProjectStore(File(base, "Projects")) }
    val recent = remember { RecentAudioStore(File(base, "RecentAudio")) }
    val library = remember { LibraryModel(store) }
    var editor by remember { mutableStateOf<EditorModel?>(null) }
    var startWithPhotos by remember { mutableStateOf(false) }

    fun open(p: com.mujassir.cutline.core.Project, photos: Boolean) {
        val fresh = runCatching { store.load(p.id) }.getOrNull() ?: return
        startWithPhotos = photos
        val player = playerFactory?.invoke(store) ?: CompositionPreviewPlayer(context, store)
        editor = EditorModel(context, fresh, store, recent, player, sampleMedia)
    }

    AnimatedContent(editor, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "root") { e ->
        if (e != null) {
            EditorScreen(e, startWithPhotos) {
                val closed = e.project
                editor = null
                // LIB-4: nothing was added, don't keep a 0:00 project.
                if (closed.clips.isEmpty() && closed.audioClips.isEmpty() && closed.textOverlays.isEmpty() && closed.captions.segments.isEmpty()) store.delete(closed.id)
                library.reload()
            }
        } else {
            LibraryScreen(library, onOpen = { open(it, false) }, onCreate = { open(library.create(), true) })
        }
    }
}
