package com.mujassir.cutline.app.editor

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.mujassir.cutline.app.ui.ChipButton
import com.mujassir.cutline.app.ui.Palette
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.engine.ExportEstimate
import com.mujassir.cutline.engine.ExportResolution
import java.io.File
import java.text.NumberFormat
import java.util.Locale

/** EXP-1…7. Full screen, at most 720 dp wide on wide windows (LAY-6). */
@Composable
fun ExportScreen(model: EditorModel, onClose: () -> Unit) {
    val context = LocalContext.current
    var resolution by remember { mutableStateOf(ExportResolution.P1080) }
    var fps by remember { mutableStateOf(30) }
    var hevc by remember { mutableStateOf(true) }
    var progress by remember { mutableStateOf<Double?>(null) }
    var done by remember { mutableStateOf<File?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }
    var startedAt by remember { mutableStateOf(0L) }
    var tookSeconds by remember { mutableStateOf(0.0) }
    val project = model.project
    val running = progress != null && done == null && error == null
    BackHandler { if (!running) onClose() }

    fun start(share: Boolean) {
        progress = 0.0; error = null; done = null; saved = false
        startedAt = System.nanoTime()
        // Media3 Transformer is loaded only here so the options form stays testable on the JVM.
        startMedia3Export(context, model, project, resolution, fps, hevc) { s ->
            when (s) {
                is ExportRunState.Running -> progress = s.progress
                is ExportRunState.Done -> {
                    done = s.file; progress = 1.0
                    tookSeconds = (System.nanoTime() - startedAt) / 1e9
                    model.player.toggles.animate.set(false)
                    if (share) share(context, s.file)
                }
                is ExportRunState.Failed -> { error = s.message; progress = null; model.player.toggles.animate.set(false) }
            }
        }
    }

    // pointerInput (not clickable) blocks taps to the editor without merging child test tags (EXP-1).
    Box(
        Modifier.fillMaxSize().background(Palette.background).pointerInput(Unit) { detectTapGestures { } }.testTag("export.screen"),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Export", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Box(Modifier.size(36.dp).clip(CircleShape).background(Palette.surface).clickable(enabled = !running, onClick = onClose).testTag("export.close"),
                    contentAlignment = Alignment.Center) { Icon(Icons.Default.Close, "Close", tint = if (running) Palette.secondaryText else Color.White) }
            }
            when {
                done != null -> {
                    val f = done!!
                    Text("Exported in ${String.format(Locale.US, "%.1f", tookSeconds)}s · ${f.length() / 1_000_000} MB", color = Color.White, modifier = Modifier.testTag("export.done"))
                    Button(if (saved) "Saved" else "Save to Photos", accent = true, tag = "export.save") { if (!saved) saved = saveToGallery(context, f) }
                    Button("Share", accent = false, tag = "export.share") { share(context, f) }
                }
                running -> {
                    Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(progress = { (progress ?: 0.0).toFloat() }, color = Palette.accent, modifier = Modifier.size(96.dp))
                        Text("${((progress ?: 0.0) * 100).toInt()}%", color = Color.White, fontSize = 18.sp, modifier = Modifier.testTag("export.progress"))
                    }
                }
                else -> {
                    Label("Resolution")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ExportResolution.entries.forEach { r -> ChipButton(r.title, isSelected = resolution == r) { resolution = r } }
                    }
                    Label("Frame rate")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(24, 30, 60).forEach { f -> ChipButton("$f fps", isSelected = fps == f) { fps = f } }
                    }
                    Label("Format")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ChipButton("HEVC", isSelected = hevc) { hevc = true }
                        ChipButton("H.264", isSelected = !hevc) { hevc = false }
                    }
                    val size = project.aspectRatio.renderSize(resolution.shortEdge)
                    val n = NumberFormat.getIntegerInstance(Locale.US)
                    Text("${n.format(size.width.toLong())}×${n.format(size.height.toLong())} · ${project.duration.timecode} · hardware encoded",
                        color = Palette.secondaryText, fontSize = 13.sp)
                    // Estimate from the selected format; start() still falls back to H.264 when HEVC isn't available.
                    val bytes = ExportEstimate.estimatedBytes(project, resolution, fps, hevc)
                    Text("Estimated size: ${String.format(Locale.US, "%.1f", bytes / 1e6)} MB", color = Color.White, modifier = Modifier.testTag("export.estimate"))
                    error?.let { Text(it, color = Palette.accent, fontSize = 13.sp) }
                    Spacer(Modifier.height(8.dp))
                    Button("Export Video", accent = true, tag = "export.start") { start(share = false) }
                    Button("Export & Share", accent = false, tag = "export.startShare") { start(share = true) }
                    Text("Share to WhatsApp, Instagram, TikTok, Messages, Nearby Share and more.", color = Palette.secondaryText,
                        fontSize = 12.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun Label(text: String) = Text(text, color = Palette.secondaryText, fontSize = 13.sp)

@Composable
private fun Button(title: String, accent: Boolean, tag: String, onClick: () -> Unit) {
    Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(if (accent) Palette.accent else Palette.surfaceRaised)
            .clickable(onClick = onClick).padding(vertical = 14.dp).testTag(tag))
}

/** EXP-5: system share sheet with a FileProvider URI, video/mp4. */
private fun share(context: Context, file: File) {
    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
    val intent = Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(intent, "Share video").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** EXP-5 Save to Photos: the gallery (Movies/Cutline). */
private fun saveToGallery(context: Context, file: File): Boolean = runCatching {
    val values = ContentValues().apply {
        put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Cutline")
    }
    val uri = context.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return false
    context.contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
    true
}.getOrDefault(false)
