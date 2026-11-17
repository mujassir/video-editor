package com.mujassir.cutline.app.editor

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mujassir.cutline.app.ui.Palette
import com.mujassir.cutline.core.AudioClip
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.ReorderStrip
import com.mujassir.cutline.core.Selection
import com.mujassir.cutline.core.TrimEdge
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.core.layout
import com.mujassir.cutline.core.movableClipIndices
import com.mujassir.cutline.core.canReorder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/** Row geometry (TML-3). */
object TimelineMetrics {
    val ruler = 20.dp
    val main = 58.dp
    val lane = 24.dp
    val audio = 30.dp
    val audioGap = 4.dp
    val handle = 16.dp
    val mainTop = ruler + 4.dp
    val textTop = mainTop + main + 6.dp
    val captionTop = textTop + lane + 4.dp
    val audioTop = captionTop + lane + 6.dp
    fun height(lanes: Int, wide: Boolean) = audioTop + (audio + audioGap) * lanes + 8.dp + if (wide) 10.dp else 0.dp
}

/**
 * The timeline (TML): the content scrolls under a fixed centre playhead; dragging scrubs, pinching
 * zooms (12–400 dp per second, default 64).
 */
@Composable
fun Timeline(model: EditorModel, onAddMedia: () -> Unit, modifier: Modifier = Modifier) {
    val project = model.project
    val density = LocalDensity.current
    var pps by remember { mutableFloatStateOf(64f) }          // dp per second
    val thumbs = remember { mutableStateMapOf<String, ImageBitmap>() }
    val scope = rememberCoroutineScope()
    var reorder by remember { mutableStateOf<ReorderDrag?>(null) }

    fun requestThumb(key: String, load: () -> android.graphics.Bitmap?) {
        if (thumbs.containsKey(key)) return
        thumbs[key] = ImageBitmap(1, 1)    // placeholder so it's requested once
        scope.launch {
            val b = withContext(Dispatchers.IO) { runCatching { load() }.getOrNull() }
            if (b != null) thumbs[key] = b.asImageBitmap()
        }
    }

    BoxWithConstraints(
        modifier.fillMaxWidth().background(Palette.background).clip(RoundedCornerShape(0.dp)).testTag("timeline")
            .pointerInput(Unit) {
                // One finger scrubs, two fingers zoom. Gestures consumed by items (handles, holds) are left alone.
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    var moved = 0f
                    var scrubbing = false
                    while (true) {
                        val ev = awaitPointerEvent()
                        val pressed = ev.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        if (pressed.size >= 2) {
                            val z = ev.calculateZoom()
                            if (z != 1f) { pps = (pps * z).coerceIn(12f, 400f); ev.changes.forEach { it.consume() } }
                            continue
                        }
                        val c = pressed.first()
                        if (c.isConsumed) { if (!scrubbing) break else continue }
                        val dx = c.positionChange().x
                        moved += dx
                        if (!scrubbing && abs(moved) > viewConfiguration.touchSlop) {
                            scrubbing = true
                            model.pause()
                        }
                        if (scrubbing) {
                            val dDp = with(density) { dx.toDp().value }
                            model.seek(model.currentTime - MediaTime.seconds((dDp / pps).toDouble()))
                            c.consume()
                        }
                    }
                    @Suppress("UNUSED_EXPRESSION") down
                }
            }
            .pointerInput(Unit) {
                // Tapping empty space deselects (TML-5).
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = true)
                    val up = waitForUpOrCancellation()
                    if (up != null && !up.isConsumed) model.select(Selection.None)
                }
            },
    ) {
        val width = maxWidth
        val center = width / 2
        fun x(t: MediaTime): Dp = center + ((t - model.currentTime).seconds * pps).toFloat().dp
        fun w(d: MediaTime): Dp = (d.seconds * pps).toFloat().dp
        val layout = project.layout
        val dimmed = reorder != null

        // Ruler.
        Canvas(Modifier.fillMaxWidth().height(TimelineMetrics.ruler)) {
            val step = when { pps >= 120 -> 0.5; pps >= 40 -> 1.0; pps >= 16 -> 5.0; else -> 10.0 }
            val startS = ((model.currentTime.seconds - center.value / pps) / step).toInt() - 1
            val endS = ((model.currentTime.seconds + center.value / pps) / step).toInt() + 1
            for (k in max(0, startS)..endS) {
                val t = k * step
                val px = (center + ((t - model.currentTime.seconds) * pps).toFloat().dp).toPx()
                drawLine(Palette.secondaryText, Offset(px, size.height * 0.55f), Offset(px, size.height), 1f)
            }
        }

        // Main track (TML-3) or the reorder strip (TML-13).
        layout.entries.forEach { e ->
            val clip = project.clips[e.index]
            val media = project.mediaItem(clip.mediaID)
            val selected = model.selection == Selection.Clip(clip.id)
            Box(
                Modifier.offset { IntOffset(x(e.range.start).roundToPx(), TimelineMetrics.mainTop.roundToPx()) }
                    .size(w(e.range.duration).coerceAtLeast(2.dp), TimelineMetrics.main)
                    .alpha(if (dimmed) 0f else 1f)
                    .clip(RoundedCornerShape(6.dp)).background(Palette.clipVideo)
                    .then(if (selected) Modifier.border(2.dp, Color.White, RoundedCornerShape(6.dp)) else Modifier)
                    .testTag("clip.${e.index}")
                    .pointerInput(clip.id, project) {
                        detectTapOrHold(holdMillis = 300, onTap = {
                            model.select(if (selected) Selection.None else Selection.Clip(clip.id))
                        }, onHold = { start ->
                            if (!project.canReorder(clip.id)) return@detectTapOrHold false
                            model.pause()
                            val startDp = with(density) { start.x.toDp() } + x(e.range.start)
                            reorder = ReorderDrag(clip.id, e.index, startDp, startDp)
                            true
                        }, onHoldDrag = { dx ->
                            reorder = reorder?.let { it.copy(fingerX = it.fingerX + with(density) { dx.toDp() }) }
                        }, onHoldEnd = {
                            reorder?.let { r ->
                                val slot = ReorderStrip.slot((r.fingerX - r.stripStart()).value.toDouble(), project.movableClipIndices)
                                model.reorder(r.clipID, slot)
                            }
                            reorder = null
                        })
                    },
            ) {
                if (media != null) {
                    Canvas(Modifier.fillMaxSize()) {
                        val tile = 58.dp.toPx()
                        val total = size.width
                        var px = 0f
                        clipRect {
                            while (px < total) {
                                val frac = ((px + tile / 2) / total).coerceIn(0f, 1f)
                                val local = MediaTime.seconds(e.range.duration.seconds * frac)
                                val st = clip.sourceTime(local)
                                val key = "${media.id}|${st.ticks / 15000}"
                                val img = thumbs[key]
                                if (img == null) requestThumb(key) { model.thumbnails.frame(media, st, 160) }
                                if (img != null && img.width > 1) {
                                    val k = max(tile / img.width, size.height / img.height)
                                    drawImageScaled(img, Offset(px, 0f), k, size.height)
                                }
                                px += tile
                            }
                        }
                    }
                }
                if (clip.isMuted) Icon(Icons.AutoMirrored.Filled.VolumeOff, null, tint = Color.White,
                    modifier = Modifier.align(Alignment.TopStart).padding(3.dp).size(14.dp))
                if (clip.titleCard != null) Text(clip.titleCard!!.title, color = Color.White, fontSize = 10.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.align(Alignment.BottomStart).padding(4.dp))
            }
            // Trim handles (TML-6), 16 dp drawn, wider to touch.
            if (selected && !dimmed) {
                for (edge in TrimEdge.entries) {
                    val ex = if (edge == TrimEdge.LEADING) x(e.range.start) - TimelineMetrics.handle else x(e.range.end)
                    Box(
                        Modifier.offset { IntOffset((ex - 14.dp).roundToPx(), TimelineMetrics.mainTop.roundToPx()) }
                            .size(TimelineMetrics.handle + 28.dp, TimelineMetrics.main)
                            .testTag(if (edge == TrimEdge.LEADING) "trim.leading" else "trim.trailing")
                            .pointerInput(clip.id, edge) {
                                var total = 0f
                                detectHorizontalDragGestures(
                                    onDragStart = { total = 0f; model.trimDrag(clip.id, edge, MediaTime.ZERO, DragPhase.Start) },
                                    onDragEnd = { model.trimDrag(clip.id, edge, MediaTime.ZERO, DragPhase.End) },
                                    onDragCancel = { model.trimDrag(clip.id, edge, MediaTime.ZERO, DragPhase.End) },
                                ) { change, dx ->
                                    change.consume()
                                    total += dx
                                    val dDp = with(density) { total.toDp().value }
                                    model.trimDrag(clip.id, edge, MediaTime.seconds((dDp / pps).toDouble()), DragPhase.Move)
                                }
                            },
                    ) {
                        Box(Modifier.align(Alignment.Center).size(TimelineMetrics.handle, TimelineMetrics.main)
                            .clip(RoundedCornerShape(4.dp)).background(Color.White))
                    }
                }
            }
            // Transition buttons between clips (TML-7).
            if (e.index + 1 < project.clips.size && !dimmed) {
                val cut = e.range.end - e.overlapOut.half()
                val active = clip.transitionOut != null
                Box(
                    Modifier.offset { IntOffset((x(cut) - 11.dp).roundToPx(), (TimelineMetrics.mainTop + TimelineMetrics.main / 2 - 11.dp).roundToPx()) }
                        .size(22.dp).clip(RoundedCornerShape(5.dp)).background(if (active) Palette.accent else Color.White)
                        .clickable { model.select(Selection.Clip(clip.id)); model.panel = EditorPanel.Transition(clip.id) }
                        .testTag("transition.${e.index}"),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.SwapHoriz, null, tint = if (active) Color.White else Color.Black, modifier = Modifier.size(14.dp)) }
            }
        }
        // "+" after the last clip (TML-8).
        if (!dimmed) {
            Box(
                Modifier.offset { IntOffset((x(layout.duration) + 8.dp).roundToPx(), (TimelineMetrics.mainTop + 9.dp).roundToPx()) }
                    .size(40.dp).clip(RoundedCornerShape(8.dp)).background(Color.White).clickable(onClick = onAddMedia).testTag("timeline.add"),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Add, "Add media", tint = Color.Black) }
        }

        // Text lane.
        project.textOverlays.forEachIndexed { i, t ->
            val selected = model.selection == Selection.Text(t.id)
            LaneBar(t.text.ifBlank { "Text" }, Palette.clipText, selected, x(t.range.start), w(t.range.duration), TimelineMetrics.textTop, "text.$i", dimmed) {
                model.select(if (selected) Selection.None else Selection.Text(t.id))
            }
        }
        // Captions lane.
        val segs = project.captions.segments
        if (segs.isNotEmpty()) {
            val start = segs.minOf { it.range.start }; val end = segs.maxOf { it.range.end }
            val selected = model.selection == Selection.Captions
            LaneBar("Captions", Palette.clipCaptions, selected, x(start), w(end - start), TimelineMetrics.captionTop, "captions", dimmed) {
                model.select(if (selected) Selection.None else Selection.Captions)
            }
        }
        // Audio lanes (TML-9, TML-10, TML-12).
        val videoEnd = project.duration
        project.audioClips.forEachIndexed { i, a ->
            AudioBar(model, a, i, videoEnd, x(a.start), w(a.timelineRange.duration), pps, dimmed)
        }

        // Reorder strip (TML-13).
        reorder?.let { r -> ReorderStripView(model, r, thumbs, ::requestThumb) }

        // Fixed centre playhead (TML-1).
        Box(Modifier.offset { IntOffset((center - 1.dp).roundToPx(), 0) }.width(2.dp).fillMaxHeight().background(Color.White).testTag("playhead"))
    }
}

/** Long-press drag state for reordering (TML-13). Positions in dp from the timeline's left edge. */
data class ReorderDrag(val clipID: UUID, val fromIndex: Int, val startX: Dp, val fingerX: Dp) {
    /** The strip is placed so the picked clip's tile starts under the finger. */
    fun stripStart(): Dp = startX - ReorderStrip.tileX(fromIndex).toFloat().dp - (ReorderStrip.TILE_SIZE / 2).toFloat().dp
}

@Composable
private fun ReorderStripView(model: EditorModel, r: ReorderDrag, thumbs: Map<String, ImageBitmap>, request: (String, () -> android.graphics.Bitmap?) -> Unit) {
    val project = model.project
    val movable = project.movableClipIndices
    val slot = ReorderStrip.slot((r.fingerX - r.stripStart()).value.toDouble(), movable)
    val tile = ReorderStrip.TILE_SIZE.toFloat().dp
    project.clips.forEachIndexed { i, clip ->
        if (clip.id == r.clipID) return@forEachIndexed
        // Others slide aside to open the landing gap.
        val visual = when {
            i > r.fromIndex && i <= slot -> i - 1
            i < r.fromIndex && i >= slot -> i + 1
            else -> i
        }
        val x by animateDpAsState(r.stripStart() + ReorderStrip.tileX(visual).toFloat().dp, tween(200), label = "tile")
        StripTile(model, clip, thumbs, request, Modifier.offset { IntOffset(x.roundToPx(), (TimelineMetrics.mainTop + 3.dp).roundToPx()) }
            .alpha(if (clip.titleCard != null) 0.5f else 1f).testTag("strip.$i"), tile)
    }
    val picked = project.clip(r.clipID) ?: return
    StripTile(model, picked, thumbs, request,
        Modifier.offset { IntOffset((r.fingerX - tile * 1.25f / 2).roundToPx(), (TimelineMetrics.mainTop - 4.dp).roundToPx()) }
            .shadow(10.dp, RoundedCornerShape(8.dp)).testTag("strip.picked"), tile * 1.25f)
}

@Composable
private fun StripTile(model: EditorModel, clip: com.mujassir.cutline.core.VideoClip, thumbs: Map<String, ImageBitmap>,
                      request: (String, () -> android.graphics.Bitmap?) -> Unit, modifier: Modifier, size: Dp) {
    val media = model.project.mediaItem(clip.mediaID)
    val mid = clip.sourceTime(MediaTime(clip.timelineDuration.ticks / 2))
    val key = "${media?.id}|${mid.ticks / 15000}"
    val img = thumbs[key]
    if (img == null && media != null) request(key) { model.thumbnails.frame(media, mid, 160) }
    Box(modifier.size(size).clip(RoundedCornerShape(8.dp)).background(Palette.clipVideo)) {
        if (img != null && img.width > 1) {
            androidx.compose.foundation.Image(img, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun LaneBar(label: String, color: Color, selected: Boolean, x: Dp, width: Dp, top: Dp, tag: String, dimmed: Boolean, onTap: () -> Unit) {
    Box(
        Modifier.offset { IntOffset(x.roundToPx(), top.roundToPx()) }.size(width.coerceAtLeast(4.dp), TimelineMetrics.lane)
            .alpha(if (dimmed) 0.4f else 1f).clip(RoundedCornerShape(5.dp)).background(color.copy(alpha = 0.85f))
            .then(if (selected) Modifier.border(2.dp, Color.White, RoundedCornerShape(5.dp)) else Modifier)
            .clickable(onClick = onTap).testTag(tag),
        contentAlignment = Alignment.CenterStart,
    ) { Text(label, color = Color.White, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 6.dp)) }
}

@Composable
private fun AudioBar(model: EditorModel, a: AudioClip, index: Int, videoEnd: MediaTime, x: Dp, width: Dp, pps: Float, dimmed: Boolean) {
    val density = LocalDensity.current
    val selected = model.selection == Selection.Audio(a.id)
    var dragDx by remember(a.id) { mutableFloatStateOf(0f) }
    val top = TimelineMetrics.audioTop + (TimelineMetrics.audio + TimelineMetrics.audioGap) * a.lane
    val peaks = model.waveforms[a.mediaID]
    // The part past the end of the video is dimmed (TML-9).
    val pastFraction = if (a.timelineRange.end > videoEnd && a.timelineRange.duration.ticks > 0)
        ((a.timelineRange.end - MediaTime.max(videoEnd, a.start)).seconds / a.timelineRange.duration.seconds).toFloat() else 0f
    Box(
        Modifier.offset { IntOffset((x + with(density) { dragDx.toDp() }).roundToPx(), top.roundToPx()) }
            .size(width.coerceAtLeast(4.dp), TimelineMetrics.audio).alpha(if (dimmed) 0.4f else 1f)
            .clip(RoundedCornerShape(5.dp)).background(Palette.clipAudio.copy(alpha = 0.85f))
            .then(if (selected) Modifier.border(2.dp, Color.White, RoundedCornerShape(5.dp)) else Modifier)
            .testTag("audio.$index")
            .pointerInput(a.id, model.project) {
                detectTapOrHold(holdMillis = 250, onTap = {
                    model.select(if (selected) Selection.None else Selection.Audio(a.id))
                }, onHold = { model.select(Selection.Audio(a.id)); dragDx = 0f; true },
                    onHoldDrag = { dx -> dragDx += dx },
                    onHoldEnd = {
                        val dDp = with(density) { dragDx.toDp().value }
                        model.moveAudio(a.id, a.start + MediaTime.seconds((dDp / pps).toDouble()))
                        dragDx = 0f
                    })
            },
    ) {
        if (peaks != null) {
            Canvas(Modifier.fillMaxSize()) {
                val media = model.project.mediaItem(a.mediaID) ?: return@Canvas
                val total = media.duration.seconds.coerceAtLeast(0.001)
                val mid = size.height / 2
                var px = 0f
                while (px < size.width) {
                    val songT = a.sourceRange.start.seconds + (px / size.width) * a.timelineRange.duration.seconds
                    val b = ((songT / total) * peaks.size).toInt().coerceIn(0, peaks.size - 1)
                    val h = (peaks[b] * (size.height - 6)).coerceAtLeast(1f)
                    drawLine(Color.White.copy(alpha = 0.55f), Offset(px, mid - h / 2), Offset(px, mid + h / 2), 2f)
                    px += 3f
                }
            }
        }
        Text(a.name.ifBlank { "Music" }, color = Color.White, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.CenterStart).padding(horizontal = 6.dp))
        if (pastFraction > 0) {
            Box(Modifier.align(Alignment.CenterEnd).fillMaxHeight().fillMaxWidth(pastFraction.coerceIn(0f, 1f)).background(Color.Black.copy(alpha = 0.5f)))
        }
    }
}

/**
 * Tap, or press and hold for `holdMillis` and then drag. A move past the touch slop before the hold
 * fires gives the gesture to the timeline (scrubbing).
 */
suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectTapOrHold(
    holdMillis: Long,
    onTap: () -> Unit,
    onHold: (Offset) -> Boolean,
    onHoldDrag: (Float) -> Unit,
    onHoldEnd: () -> Unit,
) {
    awaitEachGesture {
        val down = awaitFirstDown()
        var up: PointerInputChange? = null
        var cancelled = false
        val held = withTimeoutOrNull(holdMillis) {
            while (true) {
                val ev = awaitPointerEvent()
                val c = ev.changes.first()
                if (!c.pressed) { up = c; return@withTimeoutOrNull false }
                if ((c.position - down.position).getDistance() > viewConfiguration.touchSlop || c.isConsumed) { cancelled = true; return@withTimeoutOrNull false }
            }
            @Suppress("UNREACHABLE_CODE") false
        } == null
        if (!held) {
            if (!cancelled && up != null) { up!!.consume(); onTap() }
            return@awaitEachGesture
        }
        if (!onHold(down.position)) return@awaitEachGesture
        while (true) {
            val ev = awaitPointerEvent()
            val c = ev.changes.first()
            if (!c.pressed) { c.consume(); break }
            val dx = c.positionChange().x
            c.consume()
            if (dx != 0f) onHoldDrag(dx)
        }
        onHoldEnd()
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawImageScaled(img: ImageBitmap, topLeft: Offset, k: Float, height: Float) {
    val w = (img.width * k).roundToInt(); val h = (img.height * k).roundToInt()
    drawImage(img, dstOffset = IntOffset(topLeft.x.roundToInt(), (topLeft.y + (height - h) / 2).roundToInt()), dstSize = IntSize(w, h))
}
