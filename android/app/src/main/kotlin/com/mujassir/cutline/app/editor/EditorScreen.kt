package com.mujassir.cutline.app.editor

import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mujassir.cutline.app.ui.LocalInSidebar
import com.mujassir.cutline.app.ui.Palette
import com.mujassir.cutline.app.ui.ToastView
import com.mujassir.cutline.app.ui.ToolButton
import com.mujassir.cutline.core.AudioClip
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.Selection
import com.mujassir.cutline.core.TitleCard
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.core.hasVideoClips
import com.mujassir.cutline.core.updatingText
import com.mujassir.cutline.core.duplicatingText
import kotlinx.coroutines.launch
import java.util.Locale

/** LAY-1: the wide layout needs at least this width (and an expanded window on Android). */
val WIDE_MIN_WIDTH = 840.dp

/** PRV-9 play speeds, slowest first. */
val PREVIEW_RATES = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)

@Composable
fun EditorScreen(model: EditorModel, startWithPhotos: Boolean, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var showExport by remember { mutableStateOf(false) }
    var showAddMenu by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(20)) { uris ->
        model.importMedia(uris)
    }
    fun openPhotos() {
        model.pause()
        picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
    }
    // IMP-1 / PRV-7: the timeline "+" and the empty preview open the Photo Picker. Tests and demos get the Add menu.
    val addMedia: () -> Unit = { if (model.sampleMedia) showAddMenu = true else openPhotos() }
    LaunchedEffect(Unit) {
        // LIB-1: a new project opens the Photo Picker straight away.
        if (startWithPhotos && model.project.clips.isEmpty() && !model.sampleMedia) openPhotos()
    }
    val close: () -> Unit = { scope.launch { model.close(); onClose() } }
    BackHandler {
        when {
            model.panel != null -> model.panel = null
            model.selection != Selection.None -> model.select(Selection.None)
            else -> close()
        }
    }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    BoxWithConstraints(
        Modifier.fillMaxSize().background(Palette.background).statusBarsPadding().navigationBarsPadding()
            .onPreviewKeyEvent { e -> e.type == KeyEventType.KeyDown && handleShortcut(model, e, { showExport = true }) }
            .focusRequester(focus).focusable(),
    ) {
        val wide = maxWidth >= WIDE_MIN_WIDTH
        if (wide) WideLayout(model, close, { showExport = true }, addMedia) else PhoneLayout(model, close, { showExport = true }, addMedia)

        model.toast?.let { t ->
            Box(Modifier.align(Alignment.TopCenter).padding(top = 56.dp)) { ToastView(t) }
        }
        model.busy?.let { b ->
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)).pointerInput(Unit) { detectTapGestures { } }.testTag("busy"),
                contentAlignment = Alignment.Center) {
                Column(Modifier.clip(RoundedCornerShape(16.dp)).background(Palette.surface).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    if (b.progress != null) CircularProgressIndicator(progress = { b.progress.toFloat() }, color = Palette.accent)
                    else CircularProgressIndicator(color = Palette.accent)
                    Spacer(Modifier.height(12.dp))
                    Text(b.message, color = Color.White)
                }
            }
        }
        DropdownMenu(expanded = showAddMenu, onDismissRequest = { showAddMenu = false }) {
            DropdownMenuItem(text = { Text("Photos Library") }, onClick = { showAddMenu = false; openPhotos() })
            DropdownMenuItem(text = { Text("Sample Clips") }, modifier = Modifier.testTag("add.samples"),
                onClick = { showAddMenu = false; SampleMedia.importInto(model) })
            DropdownMenuItem(text = { Text("Sample Video") }, modifier = Modifier.testTag("add.sampleVideo"),
                onClick = { showAddMenu = false; SampleMedia.importVideoInto(model) })
            DropdownMenuItem(text = { Text("Two Sample Videos") }, modifier = Modifier.testTag("add.sampleVideos"),
                onClick = { showAddMenu = false; SampleMedia.importVideoInto(model, count = 2) })
        }
        if (showExport) {
            ExportScreen(model, onClose = { showExport = false })
        }
        if (model.panel == EditorPanel.CaptionText) {
            CaptionTextEditor(model)
        }
    }
}

/** LAY-5 keyboard shortcuts (Ctrl or Cmd). Plain keys are ignored while a text panel is open. */
private fun handleShortcut(model: EditorModel, e: androidx.compose.ui.input.key.KeyEvent, export: () -> Unit): Boolean {
    val typing = when (model.panel) {
        is EditorPanel.Text, EditorPanel.CaptionText, EditorPanel.Watermark, is EditorPanel.TitleCardPanel -> true
        else -> false
    }
    val cmd = e.isCtrlPressed || e.isMetaPressed
    val frame = MediaTime.seconds(1.0 / 30)
    return when {
        cmd && e.key == Key.Z && e.isShiftPressed && !typing -> { if (model.canRedo) model.redo(); true }
        cmd && e.key == Key.Z && !typing -> { if (model.canUndo) model.undo(); true }
        cmd && e.key == Key.B -> { if (model.project.duration > MediaTime.ZERO) model.split(); true }
        cmd && e.key == Key.E -> { if (model.project.duration > MediaTime.ZERO) { model.pause(); export() }; true }
        e.key == Key.Escape -> { if (model.panel != null) model.panel = null else model.select(Selection.None); true }
        typing || cmd -> false
        e.key == Key.Spacebar -> { model.togglePlay(); true }
        e.key == Key.DirectionLeft -> { model.pause(); model.seek(model.currentTime - if (e.isShiftPressed) MediaTime.seconds(1) else frame); true }
        e.key == Key.DirectionRight -> { model.pause(); model.seek(model.currentTime + if (e.isShiftPressed) MediaTime.seconds(1) else frame); true }
        e.key == Key.Delete || e.key == Key.Backspace -> { if (model.selection != Selection.None) model.deleteSelection(); true }
        else -> false
    }
}

@Composable
private fun PhoneLayout(model: EditorModel, close: () -> Unit, export: () -> Unit, addMedia: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TopBar(model, close, export)
        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp)) { PreviewArea(model, addMedia) }
        Transport(model)
        Timeline(model, addMedia, Modifier.height(timelineHeight(model, wide = false)))
        Box(Modifier.imePadding()) {
            val p = model.panel
            if (p != null && p != EditorPanel.CaptionText) PanelView(model, p) else Toolbar(model)
        }
    }
}

@Composable
private fun WideLayout(model: EditorModel, close: () -> Unit, export: () -> Unit, addMedia: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val sidebarWidth = (maxWidth * 0.3f).coerceIn(340.dp, 420.dp)
        Column(Modifier.fillMaxSize()) {
            TopBar(model, close, export)
            Row(Modifier.weight(1f).fillMaxWidth()) {
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    Box(Modifier.weight(1f).fillMaxWidth().padding(8.dp)) { PreviewArea(model, addMedia) }
                    Transport(model)
                }
                Sidebar(model, Modifier.width(sidebarWidth).fillMaxHeight())
            }
            Timeline(model, addMedia, Modifier.height(timelineHeight(model, wide = true)))
        }
    }
}

private fun timelineHeight(model: EditorModel, wide: Boolean): androidx.compose.ui.unit.Dp {
    val lanes = (model.project.audioClips.maxOfOrNull { it.lane } ?: 0) + 1
    return if (wide) minOf(320f, 170f + lanes * 38f).dp else minOf(250f, 150f + lanes * 34f).dp
}

/** LAY-3: the selection's tools as a 3-column grid, or the open panel. */
@Composable
private fun Sidebar(model: EditorModel, modifier: Modifier) {
    CompositionLocalProvider(LocalInSidebar provides true) {
        Column(modifier.background(Palette.surface).testTag("editor.sidebar")) {
            val p = model.panel
            if (p != null && p != EditorPanel.CaptionText) {
                Column(Modifier.verticalScroll(rememberScrollState())) { PanelView(model, p) }
            } else {
                Text(sidebarTitle(model), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 16.dp, top = 14.dp, bottom = 10.dp).testTag("sidebar.title"))
                LazyVerticalGrid(GridCells.Fixed(3), Modifier.padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    tools(model).forEach { t -> item { ToolButton(t.title, t.icon, t.isActive, t.badge, t.action) } }
                }
            }
        }
    }
}

private fun sidebarTitle(model: EditorModel) = when (val s = model.selection) {
    Selection.None -> "Project"
    is Selection.Clip -> if (model.selectedClip?.isStill == true) "Photo" else "Video Clip"
    is Selection.Text -> "Text"
    is Selection.Audio -> if (model.selectedAudio?.role == AudioClip.Role.MUSIC) "Music" else "Audio"
    Selection.Captions -> "Captions"
}

@Composable
private fun TopBar(model: EditorModel, close: () -> Unit, export: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        RoundIcon(Icons.Default.Close, "editor.close", "Close", onClick = close)
        Spacer(Modifier.width(14.dp))
        Text(model.project.aspectRatio.raw, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(CircleShape).background(Palette.surface).clickable { model.panel = EditorPanel.Canvas }
                .padding(horizontal = 12.dp, vertical = 7.dp).testTag("editor.aspect"))
        Spacer(Modifier.weight(1f))
        // PRJ-2: shown only when they can act.
        if (model.canUndo) IconAction(Icons.AutoMirrored.Filled.Undo, "editor.undo", "Undo") { model.undo() }
        if (model.canRedo) IconAction(Icons.AutoMirrored.Filled.Redo, "editor.redo", "Redo") { model.redo() }
        if (model.project.duration > MediaTime.ZERO) {
            Spacer(Modifier.width(8.dp))
            Text("Export", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp,
                modifier = Modifier.clip(CircleShape).background(Palette.accent).clickable { model.pause(); export() }
                    .padding(horizontal = 16.dp, vertical = 8.dp).testTag("editor.export"))
        }
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, tag: String, label: String, onClick: () -> Unit) {
    Box(Modifier.size(36.dp).clip(CircleShape).background(Palette.surface).clickable(onClick = onClick).testTag(tag), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = Color.White, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun IconAction(icon: ImageVector, tag: String, label: String, onClick: () -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).clickable(onClick = onClick).testTag(tag), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = Color.White)
    }
}

/** The canvas preview (PRV), the empty state (PRV-7), text dragging (PRV-6), music-only (PRV-8). */
@Composable
private fun PreviewArea(model: EditorModel, addMedia: () -> Unit) {
    val ratio = model.project.aspectRatio.value.toFloat()
    val density = LocalDensity.current
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Box(Modifier.aspectRatio(ratio).background(Color.Black).testTag("preview")) {
            AndroidView(factory = { ctx -> SurfaceView(ctx).also { model.player.attach(it) } },
                onRelease = { model.player.detach(it) }, modifier = Modifier.fillMaxSize())
            // Taps play / pause; dragging the selected text moves it (TXT-5 Custom).
            val textID = (model.selection as? Selection.Text)?.id
            Box(Modifier.fillMaxSize().pointerInput(textID) {
                if (textID == null) { detectTapGestures { model.togglePlay() }; return@pointerInput }
                var cx = 0.5; var cy = 0.5
                detectDragGestures(onDragStart = {
                    val t = model.project.text(textID) ?: return@detectDragGestures
                    val frame = model.player.overlay?.textFrame(t)
                    cx = frame?.first?.first ?: t.centerX; cy = frame?.first?.second ?: t.centerY
                    model.pause()
                }, onDragEnd = {
                    val x = cx; val y = cy
                    model.edit("Move text") { it.updatingText(textID) { t -> t.copy(anchor = null, centerX = x, centerY = y) } }
                    model.player.overlay?.dragOverride = null
                }) { change, amount ->
                    change.consume()
                    cx = (cx + amount.x / size.width).coerceIn(0.0, 1.0)
                    cy = (cy + amount.y / size.height).coerceIn(0.0, 1.0)
                    model.player.overlay?.dragOverride = textID to (cx to cy)
                    model.seek(model.currentTime)
                }
            }.pointerInput(textID) { if (textID != null) detectTapGestures { model.togglePlay() } })
            if (model.project.clips.isEmpty()) {
                Column(Modifier.fillMaxSize().background(Palette.surface).clickable(onClick = addMedia).testTag("preview.empty"),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Icon(Icons.Default.Movie, null, tint = Palette.secondaryText, modifier = Modifier.size(44.dp))
                    Spacer(Modifier.height(10.dp))
                    Text("Add videos or photos to start", color = Palette.secondaryText, fontSize = 14.sp)
                }
            } else if (model.currentTime > model.project.duration && model.project.duration > MediaTime.ZERO) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
                    Text("Music only · not in export", color = Color.White, fontSize = 13.sp, modifier = Modifier.testTag("preview.musicOnly"))
                }
            }
        }
    }
}

@Composable
private fun Transport(model: EditorModel) {
    var rateOpen by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Row(Modifier.align(Alignment.CenterStart), verticalAlignment = Alignment.CenterVertically) {
            Text(model.currentTime.timecode, color = Color.White, fontSize = 13.sp, modifier = Modifier.testTag("time.current"))
            Text(" / ${model.project.duration.timecode}", color = Palette.secondaryText, fontSize = 13.sp, modifier = Modifier.testTag("time.total"))
        }
        Box(Modifier.align(Alignment.Center).size(44.dp, 36.dp).clickable { model.togglePlay() }.testTag("editor.play"), contentAlignment = Alignment.Center) {
            Icon(if (model.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, if (model.isPlaying) "Pause" else "Play", tint = Color.White, modifier = Modifier.size(28.dp))
        }
        // PRV-9: speed button and its column of speeds above it.
        Box(Modifier.align(Alignment.CenterEnd)) {
            Text(rateTitle(model.previewRate), color = Color.White, fontSize = 13.sp,
                modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = if (rateOpen || model.previewRate != 1f) 0.28f else 0.12f))
                    .clickable { rateOpen = !rateOpen }.padding(horizontal = 8.dp, vertical = 3.dp).testTag("preview.rate"))
            DropdownMenu(expanded = rateOpen, onDismissRequest = { rateOpen = false }) {
                PREVIEW_RATES.reversed().forEach { r ->
                    DropdownMenuItem(text = { Text(rateTitle(r), fontWeight = if (r == model.previewRate) FontWeight.Bold else FontWeight.Normal) },
                        modifier = Modifier.testTag("rate.${rateTitle(r)}"),
                        onClick = { rateOpen = false; model.setRate(r) })
                }
            }
        }
    }
}

fun rateTitle(r: Float): String = String.format(Locale.US, "%s×", if (r == r.toInt().toFloat()) r.toInt().toString() else r.toString().trimEnd('0'))

data class Tool(val title: String, val icon: ImageVector, val isActive: Boolean = false, val badge: String? = null, val action: () -> Unit)

/**
 * The toolbar for the current selection (TBR-1…6), one list for the phone toolbar and the wide
 * sidebar grid.
 */
fun tools(model: EditorModel): List<Tool> {
    val p = model.project
    return when (val s = model.selection) {
        Selection.None -> buildList {
            if (p.duration > MediaTime.ZERO) {
                add(Tool("Music", Icons.Default.MusicNote) { model.select(Selection.None); model.panel = EditorPanel.Music })
                // TBR-1: Captions / Denoise need a video clip on the main track.
                if (p.hasVideoClips) {
                    add(Tool("Captions", Icons.Default.ClosedCaption, badge = "AI", isActive = p.captions.segments.isNotEmpty()) {
                        if (p.captions.segments.isEmpty()) model.panel = EditorPanel.Captions else model.select(Selection.Captions)
                    })
                    add(Tool("Denoise", Icons.Default.GraphicEq, isActive = p.noiseReduction != null) { model.panel = EditorPanel.Denoise })
                }
                add(Tool("Watermark", Icons.Default.Verified, isActive = p.watermark != null) { model.select(Selection.None); model.panel = EditorPanel.Watermark })
                add(Tool("Text", Icons.Default.TextFields) { model.addText() })
            }
            add(Tool("Intro", Icons.Default.Start) { model.select(Selection.None); model.panel = EditorPanel.TitleCardPanel(TitleCard.Placement.OPENING) })
            add(Tool("Outro", Icons.Default.KeyboardTab) { model.select(Selection.None); model.panel = EditorPanel.TitleCardPanel(TitleCard.Placement.CLOSING) })
        }
        is Selection.Clip -> {
            val c = model.selectedClip
            if (c?.isStill == true) listOf(
                Tool("Duration", Icons.Default.Timer) { model.panel = EditorPanel.Duration },
                Tool("Animate", Icons.Default.Animation, isActive = (c.photoMotion ?: com.mujassir.cutline.core.PhotoMotion.NONE) != com.mujassir.cutline.core.PhotoMotion.NONE || c.animation?.isEmpty == false) { model.panel = EditorPanel.Motion },
                Tool("Filters", Icons.Default.FilterVintage) { model.panel = EditorPanel.Filters },
                Tool("Adjust", Icons.Default.Tune) { model.panel = EditorPanel.Adjust },
                Tool("Enhance", Icons.Default.AutoFixHigh, badge = "AI") { model.autoEnhance() },
                Tool("Crop", Icons.Default.Crop) { model.panel = EditorPanel.Crop },
                Tool("Duplicate", Icons.Default.ContentCopy) { model.duplicateSelected() },
                Tool("Delete", Icons.Default.Delete) { model.deleteSelection() },
            ) else listOf(
                Tool("Split", Icons.Default.ContentCut) { model.split() },
                Tool("Voice", if (c?.isMuted == true) Icons.Default.MicOff else Icons.Default.Mic, isActive = c?.isMuted == true) { model.toggleVoice() },
                Tool("Speed", Icons.Default.Speed) { model.panel = EditorPanel.Speed },
                Tool("Reverse", Icons.Default.FastRewind, isActive = c?.isReversed == true) { model.reverseSelected() },
                Tool("Animate", Icons.Default.Animation, isActive = c?.animation?.isEmpty == false) { model.panel = EditorPanel.Motion },
                Tool("Filters", Icons.Default.FilterVintage) { model.panel = EditorPanel.Filters },
                Tool("Adjust", Icons.Default.Tune) { model.panel = EditorPanel.Adjust },
                Tool("Enhance", Icons.Default.AutoFixHigh, badge = "AI") { model.autoEnhance() },
                Tool("Cutout", Icons.Default.Person, badge = "AI", isActive = c?.backgroundRemoval != null) { model.panel = EditorPanel.Cutout },
                Tool("Reframe", Icons.Default.CenterFocusStrong, badge = "AI") { model.autoReframe() },
                Tool("Crop", Icons.Default.Crop) { model.panel = EditorPanel.Crop },
                Tool("Freeze", Icons.Default.AcUnit) { model.freezeFrame() },
                Tool("Duplicate", Icons.Default.ContentCopy) { model.duplicateSelected() },
                Tool("Delete", Icons.Default.Delete) { model.deleteSelection() },
            )
        }
        is Selection.Text -> {
            val t = p.text(s.id)
            listOf(
                Tool("Edit", Icons.Default.EditNote) { model.panel = EditorPanel.Text(s.id) },
                Tool("Duration", Icons.Default.Timer) { model.panel = EditorPanel.TextDuration(s.id) },
                Tool("Animate", Icons.Default.Animation, isActive = t?.animation?.isEmpty == false) { model.panel = EditorPanel.TextAnimate(s.id) },
                Tool("Position", Icons.Default.GridOn, isActive = t?.anchor != null) { model.panel = EditorPanel.TextPosition(s.id) },
                Tool("Duplicate", Icons.Default.ContentCopy) {
                    val id = java.util.UUID.randomUUID()
                    model.edit("Duplicate text") { it.duplicatingText(s.id, id) }
                    model.select(Selection.Text(id))
                },
                Tool("Delete", Icons.Default.Delete) { model.deleteSelection() },
            )
        }
        is Selection.Audio -> buildList {
            add(Tool("Cut", Icons.Default.ContentCut) { model.cutSelectedAudio() })
            if (model.canStartSelectedAudioHere) add(Tool("Start Here", Icons.Default.FirstPage) { model.startSelectedAudioHere() })
            if (model.selectedAudio?.role == AudioClip.Role.MUSIC) add(Tool("Duck", Icons.Default.VolumeDown) { model.panel = EditorPanel.Duck })
            if (model.canMoveSelectedAudioToStart) add(Tool("Move to Start", Icons.Default.KeyboardDoubleArrowLeft) { model.moveSelectedAudioToStart() })
            if (model.canRepeatSelectedAudio) add(Tool("Repeat", Icons.Default.Repeat) { model.repeatSelectedAudio() })
            add(Tool("Delete", Icons.Default.Delete) { model.deleteSelection() })
        }
        Selection.Captions -> listOf(
            Tool("Edit", Icons.Default.EditNote) { model.panel = EditorPanel.CaptionText },
            Tool("Style", Icons.Default.Brush) { model.panel = EditorPanel.Captions },
            Tool("Fillers", Icons.Default.FormatStrikethrough) { model.removeCaptionFillers() },
            Tool("Delete", Icons.Default.Delete) { model.deleteSelection() },
        )
    }
}

@Composable
private fun Toolbar(model: EditorModel) {
    Row(Modifier.fillMaxWidth().height(74.dp).background(Palette.surface).horizontalScroll(rememberScrollState())
        .padding(horizontal = 10.dp).testTag("toolbar"), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        tools(model).forEach { ToolButton(it.title, it.icon, it.isActive, it.badge, it.action) }
    }
}

@Composable
fun AnimatedToast(visible: Boolean, content: @Composable () -> Unit) {
    AnimatedVisibility(visible, enter = fadeIn(), exit = fadeOut()) { content() }
}
