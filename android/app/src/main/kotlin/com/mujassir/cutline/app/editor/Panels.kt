package com.mujassir.cutline.app.editor

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Block
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mujassir.cutline.app.ui.ChipButton
import com.mujassir.cutline.app.ui.LabeledSlider
import com.mujassir.cutline.app.ui.Palette
import com.mujassir.cutline.app.ui.PanelContainer
import com.mujassir.cutline.app.ui.SwatchRow
import com.mujassir.cutline.app.ui.compose
import com.mujassir.cutline.core.AspectRatio
import com.mujassir.cutline.core.BackgroundReplacement
import com.mujassir.cutline.core.CanvasBackground
import com.mujassir.cutline.core.ClipAnimation
import com.mujassir.cutline.core.ClipCombo
import com.mujassir.cutline.core.ClipEntrance
import com.mujassir.cutline.core.ColorAdjustments
import com.mujassir.cutline.core.ContentAnchor
import com.mujassir.cutline.core.ContentFit
import com.mujassir.cutline.core.CropRect
import com.mujassir.cutline.core.FilterSetting
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.NoiseReduction
import com.mujassir.cutline.core.OverlayAnchor
import com.mujassir.cutline.core.PhotoMotion
import com.mujassir.cutline.core.RGBAColor
import com.mujassir.cutline.core.Selection
import com.mujassir.cutline.core.TitleCard
import com.mujassir.cutline.core.Transition
import com.mujassir.cutline.core.TransitionKind
import com.mujassir.cutline.core.VideoClip
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.core.layout
import com.mujassir.cutline.core.movingText
import com.mujassir.cutline.core.render.FilterLooks
import com.mujassir.cutline.core.render.Rgb
import com.mujassir.cutline.core.settingPhotoMotion
import com.mujassir.cutline.core.settingSpeed
import com.mujassir.cutline.core.settingStillDuration
import com.mujassir.cutline.core.settingTextAnchor
import com.mujassir.cutline.core.settingTextDuration
import com.mujassir.cutline.core.settingTransition
import com.mujassir.cutline.core.speedAdjustableClipCount
import com.mujassir.cutline.core.titleCardClip
import com.mujassir.cutline.core.updatingAudio
import com.mujassir.cutline.core.updatingClip
import com.mujassir.cutline.core.updatingText
import com.mujassir.cutline.engine.TextFont
import com.mujassir.cutline.engine.TitleCardRenderer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlin.math.ln
import kotlin.math.exp
import kotlin.math.roundToInt

@Composable
fun PanelView(model: EditorModel, panel: EditorPanel) {
    when (panel) {
        EditorPanel.Canvas -> CanvasPanel(model)
        EditorPanel.Music -> MusicPanel(model)
        EditorPanel.Captions -> CaptionsPanel(model)
        EditorPanel.Duck -> model.selectedAudioID?.let { DuckPanel(model, it) }
        is EditorPanel.Text -> TextPanel(model, panel.id)
        is EditorPanel.TextDuration -> TextDurationPanel(model, panel.id)
        is EditorPanel.TextAnimate -> AnimatePanel(model, textID = panel.id)
        is EditorPanel.TextPosition -> TextPositionPanel(model, panel.id)
        is EditorPanel.Transition -> TransitionPanel(model, panel.clipID)
        EditorPanel.Watermark -> WatermarkPanel(model)
        is EditorPanel.TitleCardPanel -> TitleCardPanel(model, panel.placement)
        EditorPanel.Duration -> model.selectedClipID?.let { DurationPanel(model, it) }
        EditorPanel.Motion -> model.selectedClipID?.let { AnimatePanel(model, clipID = it) }
        EditorPanel.Filters -> model.selectedClipID?.let { FiltersPanel(model, it) }
        EditorPanel.Adjust -> model.selectedClipID?.let { AdjustPanel(model, it) }
        EditorPanel.Speed -> model.selectedClipID?.let { SpeedPanel(model, it) }
        EditorPanel.Crop -> model.selectedClipID?.let { CropPanel(model, it) }
        EditorPanel.Denoise -> DenoisePanel(model)
        EditorPanel.Cutout -> model.selectedClipID?.let { CutoutPanel(model, it) }
        EditorPanel.CaptionText -> {}
    }
}

private fun close(model: EditorModel): () -> Unit = { model.panel = null }

/** PRV-4: move the playhead to a frame of the clip where nothing animates. */
private fun showCleanFrame(model: EditorModel, clipID: UUID) {
    val e = model.project.layout.entry(clipID) ?: return
    val clip = model.project.clip(clipID) ?: return
    val d = e.range.duration
    var restStart = e.overlapIn
    var restEnd = d - e.overlapOut
    clip.animation?.let { a ->
        if (a.entrance != null) restStart = MediaTime.max(restStart, MediaTime.seconds(minOf(a.inDuration, d.seconds / 2)))
        if (a.exit != null) restEnd = MediaTime.min(restEnd, d - MediaTime.seconds(minOf(a.outDuration, d.seconds / 2)))
    }
    val local = model.currentTime - e.range.start
    if (local < restStart || local > MediaTime.max(restStart, restEnd)) {
        model.pause()
        model.seek(e.range.start + MediaTime((restStart.ticks + MediaTime.max(restStart, restEnd).ticks) / 2))
    }
}

// MARK: - Canvas (CNV)

@Composable
private fun CanvasPanel(model: EditorModel) {
    val p = model.project
    PanelContainer("Canvas", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AspectRatio.entries.forEach { r ->
                    ChipButton(r.raw, isSelected = p.aspectRatio == r, tag = "ratio.${r.raw}") { model.edit("Aspect ratio") { it.copy(aspectRatio = r) } }
                }
            }
            Text("Media that doesn't fit", color = Palette.secondaryText, fontSize = 13.sp)
            val fit = p.defaultFit ?: ContentFit.FIT
            val anchor = p.defaultAnchor ?: ContentAnchor.CENTER
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ContentFit.entries.forEach { f -> ChipButton(f.displayName, isSelected = fit == f) { model.setContentFit(f, anchor) } }
            }
            if (fit != ContentFit.STRETCH) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ContentAnchor.entries.forEach { a -> ChipButton(a.displayName, isSelected = anchor == a, tag = "anchor.${a.displayName}") { model.setContentFit(fit, a) } }
                }
            }
            Text("Background", color = Palette.secondaryText, fontSize = 13.sp)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ChipButton("Blur", isSelected = p.background == CanvasBackground.Blur) { model.edit("Background") { it.copy(background = CanvasBackground.Blur) } }
                SwatchRow((p.background as? CanvasBackground.Color)?.color) { c -> if (c != null) model.edit("Background") { it.copy(background = CanvasBackground.Color(c)) } }
            }
        }
    }
}

// MARK: - Music (MUS-1, MUS-10)

@Composable
private fun MusicPanel(model: EditorModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val audioPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val (file, name) = withContext(Dispatchers.IO) { copyToCache(context, uri) } ?: return@launch
            model.addMusic(file, name)
        }
    }
    val videoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val (file, name) = withContext(Dispatchers.IO) { copyToCache(context, uri) } ?: return@launch
            model.addMusic(file, "$name sound")
        }
    }
    val recent = remember(model.revision) { model.recent.entries }
    PanelContainer("Music", onDone = close(model), swipeAnywhere = false) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SourceButton("Audio Tracks", Icons.Default.AudioFile, "music.files", Modifier.weight(1f)) { audioPicker.launch(arrayOf("audio/*")) }
                SourceButton("From Video", Icons.Default.Movie, "music.fromVideo", Modifier.weight(1f)) {
                    videoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly))
                }
            }
            if (model.sampleMedia) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SampleMedia.tracks.forEach { t -> ChipButton(t.title, tag = "music.use.${t.id}") { SampleMedia.addTrack(model, t) } }
                }
            }
            if (recent.isNotEmpty()) {
                Text("Recent", color = Palette.secondaryText, fontSize = 13.sp)
                Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                    recent.forEachIndexed { i, e ->
                        Row(Modifier.fillMaxWidth().clickable { model.addMusic(model.recent.file(e), e.name, fromRecent = true) }
                            .padding(vertical = 8.dp).testTag("music.recent.$i"), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.MusicNote, null, tint = Palette.accent)
                            Spacer(Modifier.width(10.dp))
                            Text(e.name, color = Color.White, modifier = Modifier.weight(1f), maxLines = 1)
                            Text(e.duration.clock, color = Palette.secondaryText, fontSize = 13.sp)
                            Spacer(Modifier.width(10.dp))
                            Icon(Icons.Default.Add, null, tint = Color.White)
                        }
                    }
                }
            }
        }
    }
}

private fun copyToCache(context: android.content.Context, uri: Uri): Pair<File, String>? = runCatching {
    var name = "Audio"
    context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) name = c.getString(0)
    }
    val ext = name.substringAfterLast('.', "m4a")
    val out = File(context.cacheDir, "pick-${UUID.randomUUID()}.$ext")
    context.contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } } ?: return null
    out to name.substringBeforeLast('.')
}.getOrNull()

@Composable
private fun SourceButton(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tag: String, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(Palette.surfaceRaised).clickable(onClick = onClick).padding(vertical = 14.dp).testTag(tag),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, tint = Palette.accent, modifier = Modifier.size(28.dp))
        Spacer(Modifier.height(6.dp))
        Text(title, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

// MARK: - Duck (MUS-5)

@Composable
private fun DuckPanel(model: EditorModel, audioID: UUID) {
    val a = model.project.audio(audioID) ?: return
    PanelContainer("Duck", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Music volume while someone is speaking", color = Palette.secondaryText, fontSize = 13.sp)
            LabeledSlider("Music", a.resolvedDuckLevel.toFloat(), 0f..1f, { "${(it * 100).roundToInt()}%" }, steps = 19) { v ->
                model.editCoalescing("Duck level", "duck-$audioID") { it.updatingAudio(audioID) { c -> c.copy(duckLevel = v.toDouble(), autoDuck = true) } }
            }
            if (model.project.captions.segments.isEmpty()) {
                Text("Ducking finds speech from captions. Add captions to hear it.", color = Palette.secondaryText, fontSize = 12.sp)
            }
        }
    }
}

// MARK: - Captions style (CAP-4)

@Composable
private fun CaptionsPanel(model: EditorModel) {
    val track = model.project.captions
    PanelContainer("Captions", onDone = close(model), swipeAnywhere = false) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (track.segments.isEmpty()) {
                // CAP-1
                Text("Transcribe speech into animated captions. Runs entirely on your device.", color = Palette.secondaryText, fontSize = 13.sp)
                ChipButton("Generate Captions", tag = "captions.generate") { model.generateCaptions() }
                return@Column
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                com.mujassir.cutline.core.CaptionPreset.entries.forEach { p ->
                    ChipButton(p.displayName, isSelected = track.preset == p) { model.edit("Caption style") { it.copy(captions = it.captions.copy(preset = p)) } }
                }
            }
            Text("Highlight", color = Palette.secondaryText, fontSize = 13.sp)
            SwatchRow(track.highlightColor) { c -> if (c != null) model.edit("Highlight") { it.copy(captions = it.captions.copy(highlightColor = c)) } }
            LabeledSlider("Position", track.positionY.toFloat(), 0.10f..0.92f, { "${(it * 100).roundToInt()}%" }) { v ->
                model.editCoalescing("Caption position", "cappos") { it.copy(captions = it.captions.copy(positionY = v.toDouble())) }
            }
        }
    }
}

/** DNS-1: Denoise for the whole video — Off / Low / Medium / High. */
@Composable
private fun DenoisePanel(model: EditorModel) {
    val level = model.project.noiseReduction
    PanelContainer("Noise Reduction", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Removes background hiss, hum, wind and room noise from the sound of every video clip.", color = Palette.secondaryText, fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("Off", isSelected = level == null, tag = "denoise.off") { model.setNoiseReduction(null) }
                NoiseReduction.entries.forEach { l ->
                    ChipButton(l.title, isSelected = level == l, tag = "denoise.${l.raw}") { model.setNoiseReduction(l) }
                }
            }
            Text("Stronger settings remove more noise but can make voices sound thinner.", color = Palette.secondaryText, fontSize = 12.sp)
        }
    }
}

/** CUT-1: Off · Blur · Canvas · colour swatches. */
@Composable
private fun CutoutPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    val current = clip.backgroundRemoval
    PanelContainer("Remove Background", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Cuts out people automatically – no green screen.", color = Palette.secondaryText, fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("Off", isSelected = current == null, tag = "cutout.off") { model.setCutout(null) }
                ChipButton("Blur", isSelected = current == BackgroundReplacement.Blur, tag = "cutout.blur") { model.setCutout(BackgroundReplacement.Blur) }
                ChipButton("Canvas", isSelected = current == BackgroundReplacement.Transparent, tag = "cutout.canvas") { model.setCutout(BackgroundReplacement.Transparent) }
            }
            SwatchRow((current as? BackgroundReplacement.Color)?.color) { c ->
                if (c != null) model.setCutout(BackgroundReplacement.Color(c))
            }
        }
    }
}

// MARK: - Text (TXT-2…5)

@Composable
private fun TextPanel(model: EditorModel, id: UUID) {
    val t = model.project.text(id) ?: return
    var draft by remember(id) { mutableStateOf(t.text) }
    PanelContainer("Text", onDone = close(model), swipeAnywhere = false) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(draft, { v -> draft = v; model.editCoalescing("Edit text", "text-$id") { it.updatingText(id) { o -> o.copy(text = v) } } },
                singleLine = false, maxLines = 3, modifier = Modifier.fillMaxWidth().testTag("text.field"),
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Palette.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { model.panel = null }))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextFont.entries.forEach { f ->
                    ChipButton(f.title, isSelected = t.style.fontName == f.postScript, tag = "font.${f.title}") {
                        model.edit("Font") { it.updatingText(id) { o -> o.copy(style = o.style.copy(fontName = f.postScript)) } }
                    }
                }
            }
            SwatchRow(t.style.color) { c -> if (c != null) model.edit("Text color") { it.updatingText(id) { o -> o.copy(style = o.style.copy(color = c)) } } }
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Toggle("Outline", t.style.outlineColor != null) { on ->
                    model.edit("Outline") { it.updatingText(id) { o -> o.copy(style = o.style.copy(outlineColor = if (on) RGBAColor.BLACK else null, outlineWidth = if (on) 0.08 else 0.0)) } }
                }
                Toggle("Label", t.style.backgroundColor != null) { on ->
                    model.edit("Label") { it.updatingText(id) { o -> o.copy(style = o.style.copy(backgroundColor = if (on) RGBAColor(0.0, 0.0, 0.0, 0.6) else null)) } }
                }
                Toggle("Shadow", t.style.shadow) { on -> model.edit("Shadow") { it.updatingText(id) { o -> o.copy(style = o.style.copy(shadow = on)) } } }
            }
            // Size is shown as 30–160 (×1000 of the canvas-height fraction).
            LabeledSlider("Size", (t.style.size * 1000).toFloat(), 30f..160f, { "${it.roundToInt()}" }) { v ->
                model.editCoalescing("Text size", "tsize-$id") { it.updatingText(id) { o -> o.copy(style = o.style.copy(size = v / 1000.0)) } }
            }
        }
    }
}

@Composable
private fun Toggle(title: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontSize = 13.sp)
        Spacer(Modifier.width(6.dp))
        Switch(on, onChange, colors = SwitchDefaults.colors(checkedTrackColor = Palette.accent), modifier = Modifier.testTag("toggle.$title"))
    }
}

@Composable
private fun TextDurationPanel(model: EditorModel, id: UUID) {
    val t = model.project.text(id) ?: return
    PanelContainer("Text Duration", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(String.format(Locale.US, "%.1f s · starts %s", t.range.duration.seconds, t.range.start.timecode), color = Color.White,
                fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("textDuration.value"))
            LabeledSlider("Duration", t.range.duration.seconds.toFloat(), 0.5f..30f, { String.format(Locale.US, "%.1fs", it) }, tag = "slider.TextDuration") { v ->
                val r = (v * 10).roundToInt() / 10.0
                model.editCoalescing("Text duration", "tdur-$id") { it.settingTextDuration(id, MediaTime.seconds(r)) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(2.0, 3.0, 5.0, 10.0).forEach { v ->
                    ChipButton("${v.toInt()}s", isSelected = kotlin.math.abs(t.range.duration.seconds - v) < 0.05) { model.edit("Text duration") { it.settingTextDuration(id, MediaTime.seconds(v)) } }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("Start at playhead") { val c = model.currentTime; model.edit("Move text") { it.movingText(id, c) } }
                ChipButton("Whole video") {
                    model.edit("Text duration") { p -> p.movingText(id, MediaTime.ZERO).let { q -> q.updatingText(id) { o -> o.copy(range = o.range.copy(duration = MediaTime.max(MediaTime.seconds(0.5), q.duration))) } } }
                }
            }
        }
    }
}

@Composable
private fun TextPositionPanel(model: EditorModel, id: UUID) {
    val t = model.project.text(id) ?: return
    PanelContainer("Position", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            AnchorGrid(t.anchor, "tpos") { a -> model.edit("Text position") { it.settingTextAnchor(id, a) } }
            ChipButton("Custom", isSelected = t.anchor == null, tag = "tpos.custom") { model.edit("Text position") { it.settingTextAnchor(id, null) } }
            Text("Tip: drag the text on the preview to place it anywhere.", color = Palette.secondaryText, fontSize = 12.sp)
        }
    }
}

@Composable
private fun AnchorGrid(selected: OverlayAnchor?, prefix: String, onPick: (OverlayAnchor) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OverlayAnchor.entries.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                row.forEach { a ->
                    Box(Modifier.size(64.dp, 36.dp).clip(RoundedCornerShape(8.dp)).background(if (selected == a) Palette.accent else Palette.surfaceRaised)
                        .clickable { onPick(a) }.testTag("$prefix.${a.name}"), contentAlignment = Alignment.Center) {
                        Text(a.displayName, color = Color.White, fontSize = 10.sp)
                    }
                }
            }
        }
    }
}

// MARK: - Animate (ANM, TXT-4)

@Composable
private fun AnimatePanel(model: EditorModel, clipID: UUID? = null, textID: UUID? = null) {
    val clip = clipID?.let { model.project.clip(it) }
    val text = textID?.let { model.project.text(it) }
    if (clip == null && text == null) return
    val anim = (clip?.animation ?: text?.animation) ?: ClipAnimation()
    val isStill = clip?.isStill == true
    val tabs = buildList { add("In"); add("Out"); add("Combo"); if (isStill) add("Motion") }
    var tab by remember { mutableStateOf(0) }
    fun set(a: ClipAnimation?) {
        val value = a?.takeIf { !it.isEmpty }
        if (clip != null) model.edit("Animation") { it.updatingClip(clip.id) { c -> c.copy(animation = value) } }
        else if (text != null) model.edit("Animation") { it.updatingText(text.id) { o -> o.copy(animation = value) } }
        // PRV-5: play the part where it happens.
        val start = clip?.let { model.project.layout.entry(it.id)?.range } ?: text?.range ?: return
        when (tabs[tab]) {
            "In" -> { model.seek(start.start); model.play() }
            "Out" -> { model.seek(MediaTime.max(start.start, start.end - MediaTime.seconds(1.5))); model.play() }
        }
    }
    PanelContainer(if (text != null) "Animate Text" else "Animate", onDone = close(model), swipeAnywhere = false) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TabRow(tab, containerColor = Palette.surface, contentColor = Color.White, modifier = Modifier.testTag("animate.tabs")) {
                tabs.forEachIndexed { i, t -> Tab(selected = tab == i, onClick = { tab = i }, text = { Text(t) }) }
            }
            when (tabs[tab]) {
                "In", "Out" -> {
                    val isIn = tabs[tab] == "In"
                    val current = if (isIn) anim.entrance else anim.exit
                    TileGrid(listOf<Pair<String, ClipEntrance?>>("None" to null) + ClipEntrance.entries.map { it.displayName to it }, current,
                        prefix = if (isIn) "anim.In" else "anim.Out") { k -> set(if (isIn) anim.copy(entrance = k) else anim.copy(exit = k)) }
                    LabeledSlider("Length", (if (isIn) anim.inDuration else anim.outDuration).toFloat(), 0.2f..3f, { String.format(Locale.US, "%.1fs", it) }) { v ->
                        val a = if (isIn) anim.copy(inDuration = v.toDouble()) else anim.copy(outDuration = v.toDouble())
                        if (clip != null) model.editCoalescing("Animation length", "alen-${clip.id}") { it.updatingClip(clip.id) { c -> c.copy(animation = a) } }
                        else if (text != null) model.editCoalescing("Animation length", "alen-${text.id}") { it.updatingText(text.id) { o -> o.copy(animation = a) } }
                    }
                }
                "Combo" -> TileGrid(listOf<Pair<String, ClipCombo?>>("None" to null) + ClipCombo.entries.map { it.displayName to it }, anim.combo, "anim.combo") { k -> set(anim.copy(combo = k)) }
                "Motion" -> {
                    val c = clip ?: return@Column
                    TileGrid(PhotoMotion.entries.map { it.displayName to it }, c.photoMotion ?: PhotoMotion.NONE, "motion") { m ->
                        model.edit("Motion") { it.settingPhotoMotion(m, c.id) }
                        model.project.layout.entry(c.id)?.let { e -> model.seek(e.range.start); model.play() }
                    }
                    if (model.project.clips.count { it.kind == MediaKind.PHOTO } > 1) {
                        ChipButton("Apply to all photos") { model.edit("Motion") { it.settingPhotoMotion(c.photoMotion, c.id, allPhotos = true) }; model.showToast("Applied to all photos") }
                    }
                }
            }
            if (clip != null && tabs[tab] != "Motion" && model.project.clips.size > 1) {
                ChipButton("Apply to all clips", tag = "animate.applyAll") { model.applyAnimationToAll(clip.animation) }
            }
        }
    }
}

@Composable
private fun <T> TileGrid(items: List<Pair<String, T>>, selected: T, prefix: String, onPick: (T) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items.forEach { (title, value) ->
            Box(Modifier.size(76.dp, 44.dp).clip(RoundedCornerShape(10.dp)).background(if (value == selected) Palette.accent else Palette.surfaceRaised)
                .clickable { onPick(value) }.testTag("$prefix.${(value as? Enum<*>)?.name ?: "none"}"), contentAlignment = Alignment.Center) {
                Text(title, color = Color.White, fontSize = 11.sp)
            }
        }
    }
}

// MARK: - Transition (TRN)

@Composable
private fun TransitionPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    val t = clip.transitionOut
    fun previewTransition() {
        val e = model.project.layout.entry(clipID) ?: return
        model.seek(MediaTime.max(MediaTime.ZERO, e.range.end - e.overlapOut - MediaTime.seconds(0.4))); model.play()
    }
    PanelContainer("Transition", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TileGrid(listOf<Pair<String, TransitionKind?>>("None" to null) + TransitionKind.entries.map { it.displayName to it }, t?.kind, "transition") { k ->
                model.edit("Transition") { it.settingTransition(k?.let { kind -> Transition(kind, t?.duration ?: MediaTime.seconds(0.5)) }, clipID) }
                if (k != null) previewTransition()
            }
            if (t != null) {
                LabeledSlider("Duration", t.duration.seconds.toFloat(), 0.2f..2f, { String.format(Locale.US, "%.1fs", it) }) { v ->
                    model.editCoalescing("Transition length", "tlen-$clipID") { it.settingTransition(t.copy(duration = MediaTime.seconds(v.toDouble())), clipID) }
                }
            }
        }
    }
}

// MARK: - Watermark (WMK)

@Composable
private fun WatermarkPanel(model: EditorModel) {
    val w = model.project.watermark
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let { model.setWatermarkImage(it) } }
    PanelContainer("Watermark", onDone = close(model), swipeAnywhere = false) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("Text", isSelected = w?.kind == com.mujassir.cutline.core.Watermark.Kind.TEXT) { model.setWatermark { it.copy(kind = com.mujassir.cutline.core.Watermark.Kind.TEXT) } }
                ChipButton("Image", isSelected = w?.kind == com.mujassir.cutline.core.Watermark.Kind.IMAGE) {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
                if (w != null) ChipButton("Remove", tag = "watermark.remove") { model.setWatermark { null } }
            }
            if (w != null) {
                if (w.kind == com.mujassir.cutline.core.Watermark.Kind.TEXT) {
                    var draft by remember { mutableStateOf(w.text) }
                    OutlinedTextField(draft, { v -> draft = v; model.editCoalescing("Watermark text", "wmtext") { it.copy(watermark = it.watermark?.copy(text = v)) } },
                        singleLine = true, modifier = Modifier.fillMaxWidth().testTag("watermark.text"),
                        colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Palette.accent))
                }
                AnchorGrid(w.anchor, "wmpos") { a -> model.setWatermark { it.copy(anchor = a) } }
                LabeledSlider("Size", w.size.toFloat(), 0.08f..0.5f, { "${(it * 100).roundToInt()}%" }) { v ->
                    model.editCoalescing("Watermark size", "wmsize") { it.copy(watermark = it.watermark?.copy(size = v.toDouble())) }
                }
                LabeledSlider("Opacity", w.opacity.toFloat(), 0.1f..1f, { "${(it * 100).roundToInt()}%" }) { v ->
                    model.editCoalescing("Watermark opacity", "wmopacity") { it.copy(watermark = it.watermark?.copy(opacity = v.toDouble())) }
                }
            }
        }
    }
}

// MARK: - Opening and closing slides (TTL)

@Composable
private fun TitleCardPanel(model: EditorModel, placement: TitleCard.Placement) {
    val existing = model.project.titleCardClip(placement)
    var card by remember(placement) {
        mutableStateOf(existing?.titleCard ?: TitleCard(placement, if (placement == TitleCard.Placement.OPENING) model.project.name else "Thanks for watching"))
    }
    var seconds by remember(placement) { mutableStateOf(existing?.sourceRange?.duration?.seconds ?: 3.0) }
    val preview by produceState<ImageBitmap?>(null, card) {
        value = withContext(Dispatchers.Default) { TitleCardRenderer.render(card, 360).asImageBitmap() }
    }
    val title = if (placement == TitleCard.Placement.OPENING) "Opening Slide" else "Closing Slide"
    PanelContainer(title, onDone = { model.saveTitleCard(card, seconds); model.panel = null }, onSwipeDown = { model.panel = null }, swipeAnywhere = false) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                preview?.let { Image(it, null, Modifier.size(84.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop) }
                Spacer(Modifier.width(12.dp))
                Text(if (existing == null) "Tap ✓ to add the slide" else "Tap ✓ to save changes", color = Palette.secondaryText, fontSize = 13.sp)
            }
            OutlinedTextField(card.title, { card = card.copy(title = it) }, label = { Text("Title") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("titleCard.title"),
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Palette.accent))
            OutlinedTextField(card.subtitle, { card = card.copy(subtitle = it) }, label = { Text("Subtitle (optional)") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("titleCard.subtitle"),
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Palette.accent))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TitleCard.PRESETS.forEach { p ->
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clickable { card = card.applying(p) }.testTag("titleStyle.${p.id}")) {
                        Box(Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)).background(p.background.compose())
                            .border(if (card.preset?.id == p.id) 2.5.dp else 1.dp, if (card.preset?.id == p.id) Palette.accent else Palette.hairline, RoundedCornerShape(8.dp)),
                            contentAlignment = Alignment.Center) { Box(Modifier.size(14.dp, 3.dp).background(p.accent.compose())) }
                        Text(p.name, color = Color.White, fontSize = 10.sp)
                    }
                }
            }
            LabeledSlider("Duration", seconds.toFloat(), 1f..10f, { String.format(Locale.US, "%.1fs", it) }) { seconds = (it * 10).roundToInt() / 10.0 }
            if (existing != null) ChipButton("Remove", tag = "titleCard.remove") { model.removeTitleCard(placement); model.panel = null }
        }
    }
}

// MARK: - Clip panels

@Composable
private fun DurationPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    LaunchedEffect(clipID) { showCleanFrame(model, clipID) }
    val photos = model.project.clips.count { it.kind == MediaKind.PHOTO }
    PanelContainer("Duration", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(String.format(Locale.US, "%.1f s", clip.sourceRange.duration.seconds), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.testTag("duration.value"))
            LabeledSlider("Duration", clip.sourceRange.duration.seconds.toFloat(), 0.5f..30f, { String.format(Locale.US, "%.1fs", it) }, tag = "slider.Duration") { v ->
                model.editCoalescing("Duration", "dur-$clipID") { it.settingStillDuration(MediaTime.seconds((v * 10).roundToInt() / 10.0), clipID) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(2.0, 3.0, 5.0, 10.0).forEach { v -> ChipButton("${v.toInt()}s") { model.edit("Duration") { it.settingStillDuration(MediaTime.seconds(v), clipID) } } }
            }
            if (photos >= 2) {
                ChipButton("Apply to all $photos photos", tag = "duration.applyAll") {
                    val d = clip.sourceRange.duration
                    model.edit("Duration") { it.settingStillDuration(d, clipID, allPhotos = true) }
                    model.showToast(String.format(Locale.US, "All photos set to %.1f s", d.seconds))
                }
            }
        }
    }
}

@Composable
private fun FiltersPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    LaunchedEffect(clipID) { showCleanFrame(model, clipID) }
    val media = model.project.mediaItem(clip.mediaID)
    // FLT-2: thumbnails are the clip's own frame with each look applied (CPU, 120 px).
    val base by produceState<android.graphics.Bitmap?>(null, clipID) {
        value = withContext(Dispatchers.IO) { media?.let { model.thumbnails.frame(it, clip.sourceTime(MediaTime(clip.timelineDuration.ticks / 2)), 120) } }
    }
    PanelContainer("Filters", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterTile("None", "none", base, null, clip.filter == null) { model.edit("Filter") { it.updatingClip(clipID) { c -> c.copy(filter = null) } } }
                FilterLooks.ALL.forEach { look ->
                    FilterTile(look.name, look.id, base, look.id, clip.filter?.filterID == look.id) {
                        model.edit("Filter") { it.updatingClip(clipID) { c -> c.copy(filter = FilterSetting(look.id, c.filter?.intensity ?: 1.0)) } }
                    }
                }
            }
            clip.filter?.let { f ->
                LabeledSlider("Intensity", f.intensity.toFloat(), 0f..1f, { "${(it * 100).roundToInt()}%" }) { v ->
                    model.editCoalescing("Filter intensity", "fint-$clipID") { it.updatingClip(clipID) { c -> c.copy(filter = c.filter?.copy(intensity = v.toDouble())) } }
                }
            }
        }
    }
}

@Composable
private fun FilterTile(title: String, id: String, base: android.graphics.Bitmap?, lookID: String?, selected: Boolean, onClick: () -> Unit) {
    val img by produceState<ImageBitmap?>(null, base, lookID) {
        value = base?.let { b -> withContext(Dispatchers.Default) { graded(b, lookID).asImageBitmap() } }
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clickable(onClick = onClick).testTag("filter.$id")) {
        Box(Modifier.size(64.dp).clip(RoundedCornerShape(8.dp)).background(Palette.surfaceRaised)
            .border(if (selected) 2.5.dp else 0.dp, if (selected) Palette.accent else Color.Transparent, RoundedCornerShape(8.dp))) {
            img?.let { Image(it, null, contentScale = ContentScale.Crop, modifier = Modifier.size(64.dp)) }
                ?: if (lookID == null) Icon(Icons.Default.Block, null, tint = Palette.secondaryText, modifier = Modifier.align(Alignment.Center)) else Unit
        }
        Text(title, color = if (selected) Palette.accent else Color.White, fontSize = 11.sp)
    }
}

private fun graded(src: android.graphics.Bitmap, lookID: String?): android.graphics.Bitmap {
    val b = src.copy(android.graphics.Bitmap.Config.ARGB_8888, true)
    if (lookID == null) return b
    val px = IntArray(b.width * b.height)
    b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
    for (i in px.indices) {
        val p = px[i]
        val c = FilterLooks.grade(lookID, Rgb(((p shr 16) and 255) / 255.0, ((p shr 8) and 255) / 255.0, (p and 255) / 255.0))
        px[i] = (p and 0xFF000000.toInt()) or ((c.r * 255).roundToInt() shl 16) or ((c.g * 255).roundToInt() shl 8) or (c.b * 255).roundToInt()
    }
    b.setPixels(px, 0, b.width, 0, 0, b.width, b.height)
    return b
}

@Composable
private fun AdjustPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    LaunchedEffect(clipID) { showCleanFrame(model, clipID) }
    val a = clip.adjustments
    fun set(label: String, change: (ColorAdjustments) -> ColorAdjustments) =
        model.editCoalescing(label, "adj-$label-$clipID") { it.updatingClip(clipID) { c -> c.copy(adjustments = change(c.adjustments)) } }
    PanelContainer("Adjust", onDone = close(model), swipeAnywhere = false) {
        Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            val pm: (Float) -> String = { "${(it * 100).roundToInt()}" }
            LabeledSlider("Exposure", a.exposure.toFloat(), -1f..1f, pm) { v -> set("Exposure") { it.copy(exposure = v.toDouble()) } }
            LabeledSlider("Contrast", a.contrast.toFloat(), -1f..1f, pm) { v -> set("Contrast") { it.copy(contrast = v.toDouble()) } }
            LabeledSlider("Saturation", a.saturation.toFloat(), -1f..1f, pm) { v -> set("Saturation") { it.copy(saturation = v.toDouble()) } }
            LabeledSlider("Warmth", a.warmth.toFloat(), -1f..1f, pm) { v -> set("Warmth") { it.copy(warmth = v.toDouble()) } }
            LabeledSlider("Highlights", a.highlights.toFloat(), -1f..1f, pm) { v -> set("Highlights") { it.copy(highlights = v.toDouble()) } }
            LabeledSlider("Shadows", a.shadows.toFloat(), -1f..1f, pm) { v -> set("Shadows") { it.copy(shadows = v.toDouble()) } }
            LabeledSlider("Vignette", a.vignette.toFloat(), 0f..1f, pm) { v -> set("Vignette") { it.copy(vignette = v.toDouble()) } }
            LabeledSlider("Sharpen", a.sharpen.toFloat(), 0f..1f, pm) { v -> set("Sharpen") { it.copy(sharpen = v.toDouble()) } }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("Auto Enhance", tag = "adjust.auto") { model.autoEnhance() }
                ChipButton("Reset", tag = "adjust.reset") { model.edit("Reset") { it.updatingClip(clipID) { c -> c.copy(adjustments = ColorAdjustments()) } } }
            }
        }
    }
}

@Composable
private fun SpeedPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    val videoCount = model.project.speedAdjustableClipCount
    LaunchedEffect(clipID) { showCleanFrame(model, clipID) }
    // SPD-1: logarithmic slider 0.1–10, rounded to 0.05. SPD-4: Apply to all.
    PanelContainer("Speed", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(speedTitle(clip.speed), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("speed.value"))
            LabeledSlider("Speed", ln(clip.speed).toFloat(), ln(0.1f)..ln(10f), { speedTitle(exp(it.toDouble())) }, tag = "slider.Speed") { v ->
                val sp = ((exp(v.toDouble()) / 0.05).roundToInt() * 0.05).coerceIn(0.1, 10.0)
                model.editCoalescing("Speed", "speed-$clipID") { it.settingSpeed(sp, clipID) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(0.25, 0.5, 1.0, 2.0, 3.0, 4.0).forEach { v ->
                    ChipButton(speedTitle(v), isSelected = kotlin.math.abs(clip.speed - v) < 0.001) { model.edit("Speed") { it.settingSpeed(v, clipID) } }
                }
            }
            if (videoCount >= 2) {
                ChipButton("Apply to all $videoCount clips", tag = "speed.applyAll") { model.applySpeedToAll(clip.speed) }
            }
        }
    }
}

fun speedTitle(v: Double): String {
    val r = (v * 100).roundToInt() / 100.0
    return (if (r == r.toInt().toDouble()) r.toInt().toString() else r.toString().trimEnd('0')) + "×"
}

@Composable
private fun CropPanel(model: EditorModel, clipID: UUID) {
    val clip = model.project.clip(clipID) ?: return
    LaunchedEffect(clipID) { showCleanFrame(model, clipID) }
    val t = clip.transform
    fun set(label: String, change: (VideoClip) -> VideoClip) = model.edit(label) { it.updatingClip(clipID, change) }
    PanelContainer("Crop", onDone = close(model)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("Rotate") { set("Rotate") { c -> c.copy(transform = c.transform.copy(quarterTurns = (c.transform.quarterTurns + 1) % 4)) } }
                ChipButton("Flip H", isSelected = t.flipHorizontal) { set("Flip") { c -> c.copy(transform = c.transform.copy(flipHorizontal = !c.transform.flipHorizontal)) } }
                ChipButton("Flip V", isSelected = t.flipVertical) { set("Flip") { c -> c.copy(transform = c.transform.copy(flipVertical = !c.transform.flipVertical)) } }
                // CRP-2: cycles Fit → Fill → Stretch.
                ChipButton(t.fit.displayName, tag = "crop.fit") {
                    set("Fit") { c -> c.copy(transform = c.transform.copy(fit = ContentFit.entries[(c.transform.fit.ordinal + 1) % 3])) }
                }
            }
            LabeledSlider("Zoom", t.scale.toFloat(), 0.5f..3f, { String.format(Locale.US, "%.2f×", it) }) { v ->
                model.editCoalescing("Zoom", "zoom-$clipID") { it.updatingClip(clipID) { c -> c.copy(transform = c.transform.copy(scale = v.toDouble())) } }
            }
            val media = model.project.mediaItem(clip.mediaID)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("Original" to null, "1:1" to 1.0, "4:5" to 0.8, "16:9" to 16.0 / 9).forEach { (title, ratio) ->
                    ChipButton(title) {
                        set("Crop") { c -> c.copy(transform = c.transform.copy(crop = centredCrop(media?.naturalSize, ratio))) }
                    }
                }
            }
        }
    }
}

/** CRP-4: a centred crop of the source at a ratio (width ÷ height), or the full frame. */
fun centredCrop(size: com.mujassir.cutline.core.Size?, ratio: Double?): CropRect {
    if (size == null || ratio == null || size.width <= 0 || size.height <= 0) return CropRect.FULL
    val src = size.width / size.height
    return if (src > ratio) { val w = ratio / src; CropRect((1 - w) / 2, 0.0, w, 1.0) }
    else { val h = src / ratio; CropRect(0.0, (1 - h) / 2, 1.0, h) }
}

@Suppress("unused") private fun selectionFor(id: UUID) = Selection.Clip(id)
