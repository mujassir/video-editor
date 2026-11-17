package com.mujassir.cutline.app.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mujassir.cutline.core.RGBAColor
import kotlin.math.roundToInt

/** Visual language (FEATURES §14). */
object Palette {
    val background = Color(0xFF0E0E11)
    val surface = Color(0xFF1C1C20)
    val surfaceRaised = Color(0xFF29292E)
    val accent = Color(0xFFFF3C61)
    val accentSoft = accent.copy(alpha = 0.18f)
    val secondaryText = Color.White.copy(alpha = 0.6f)
    val hairline = Color.White.copy(alpha = 0.08f)
    val clipVideo = Color(0.25f, 0.45f, 0.95f)
    val clipAudio = Color(0.20f, 0.75f, 0.55f)
    val clipText = Color(0.95f, 0.60f, 0.20f)
    val clipCaptions = Color(0.70f, 0.45f, 0.95f)
}

/** The 8 swatches shared by text, captions and cut-out (FEATURES §14). */
val SWATCHES = listOf(
    RGBAColor.WHITE, RGBAColor.BLACK, RGBAColor(1.0, 0.86, 0.1), RGBAColor(1.0, 0.24, 0.38),
    RGBAColor(0.25, 0.55, 1.0), RGBAColor(0.2, 0.8, 0.55), RGBAColor(0.65, 0.4, 0.95), RGBAColor(1.0, 0.55, 0.15),
)

fun RGBAColor.compose() = Color(r.toFloat(), g.toFloat(), b.toFloat(), a.toFloat())

@Composable
fun CutlineTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Palette.accent, onPrimary = Color.White, background = Palette.background,
            surface = Palette.surface, onSurface = Color.White, onBackground = Color.White,
            surfaceVariant = Palette.surfaceRaised,
        ),
        content = content,
    )
}

/** True inside the wide layout's sidebar (LAY-3): tools are tiles, panels don't swipe. */
val LocalInSidebar = compositionLocalOf { false }

/** Toolbar button: icon over a label (TBR). Identifier `tool.<Title>`. */
@Composable
fun ToolButton(
    title: String, icon: ImageVector, isActive: Boolean = false, badge: String? = null, onClick: () -> Unit,
) {
    val inSidebar = LocalInSidebar.current
    val tint = if (isActive) Palette.accent else Color.White
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .then(if (inSidebar) Modifier.fillMaxWidth().height(66.dp).clip(RoundedCornerShape(12.dp)).background(Palette.surfaceRaised) else Modifier.widthIn(min = 58.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 6.dp)
            .testTag("tool.$title"),
    ) {
        Box {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
            if (badge != null) {
                Text(badge, fontSize = 8.sp, fontWeight = FontWeight.Black, color = Color.White,
                    modifier = Modifier.align(Alignment.TopEnd).offset(10.dp, (-4).dp).background(Palette.accent, CircleShape).padding(horizontal = 3.dp))
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(title, fontSize = 11.sp, color = tint, maxLines = 1)
    }
}

/** Option chip (FEATURES §14). Identifier `chip.<Title>`. */
@Composable
fun ChipButton(title: String, isSelected: Boolean = false, tag: String = "chip.$title", onClick: () -> Unit) {
    Text(
        title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White,
        modifier = Modifier.clip(CircleShape).background(if (isSelected) Palette.accent else Palette.surfaceRaised)
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics { selected = isSelected }.testTag(tag),
    )
}

/** Panel header: title on the left, optional Undo, accent ✓ on the right (FEATURES §14). */
@Composable
fun PanelHeader(title: String, onDone: () -> Unit, onUndo: (() -> Unit)? = null, canUndo: Boolean = true) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 4.dp)) {
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.weight(1f))
        if (onUndo != null) {
            Box(Modifier.size(36.dp).clip(CircleShape).background(Palette.surfaceRaised).clickable(enabled = canUndo, onClick = onUndo).testTag("panel.undo"),
                contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = "Undo", tint = if (canUndo) Color.White else Palette.secondaryText)
            }
            Spacer(Modifier.size(10.dp))
        }
        Box(Modifier.size(36.dp).clip(CircleShape).background(Palette.accent).clickable(onClick = onDone).testTag("panel.done")
            .semantics { contentDescription = "Done" }, contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Check, contentDescription = null, tint = Color.White)
        }
    }
}

/**
 * A bottom panel (EDT-1): grabber, header, content. A short swipe down closes it (more than 30 dp,
 * or a quick flick). In the wide layout's sidebar there's no grabber and no swipe (LAY-3).
 * With `swipeAnywhere = false` only the header row swipes, so scrolling lists never close it.
 */
@Composable
fun PanelContainer(
    title: String,
    onDone: () -> Unit,
    onSwipeDown: (() -> Unit)? = null,
    swipeAnywhere: Boolean = true,
    onUndo: (() -> Unit)? = null,
    canUndo: Boolean = true,
    content: @Composable () -> Unit,
) {
    val inSidebar = LocalInSidebar.current
    var drag by remember { mutableFloatStateOf(0f) }
    val animated by animateFloatAsState(drag, spring(), label = "panelDrag")
    val close = onSwipeDown ?: onDone
    // Drag deltas are summed (the panel moves under the finger, so positions would cancel out).
    val swipe = Modifier.pointerInput(inSidebar) {
        if (inSidebar) return@pointerInput
        var total = 0f
        detectVerticalDragGestures(
            onDragStart = { total = 0f },
            onDragEnd = { if (total > 30.dp.toPx()) close(); total = 0f; drag = 0f },
            onDragCancel = { total = 0f; drag = 0f },
        ) { change, amount ->
            total += amount
            if (total > 0) { drag = total; change.consume() }
        }
    }
    Column(
        Modifier.fillMaxWidth().offset { IntOffset(0, animated.roundToInt()) }.background(Palette.surface)
            .then(if (swipeAnywhere) swipe else Modifier).testTag("panel.$title"),
    ) {
        Box(Modifier.fillMaxWidth().then(if (!swipeAnywhere) swipe else Modifier)) {
            if (!inSidebar) {
                Box(Modifier.align(Alignment.TopCenter).padding(top = 5.dp).size(36.dp, 5.dp).clip(CircleShape).background(Palette.secondaryText))
            }
            PanelHeader(title, onDone, onUndo, canUndo)
        }
        Box(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp)) { content() }
    }
}

/** A labelled slider row with a value readout. */
@Composable
fun LabeledSlider(
    title: String, value: Float, range: ClosedFloatingPointRange<Float>, format: (Float) -> String,
    steps: Int = 0, tag: String = "slider.$title", onChange: (Float) -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth()) {
            Text(title, fontSize = 13.sp, color = Color.White, modifier = Modifier.weight(1f))
            Text(format(value), fontSize = 13.sp, color = Palette.secondaryText)
        }
        Slider(
            value = value, onValueChange = onChange, valueRange = range, steps = steps,
            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent, inactiveTrackColor = Palette.surfaceRaised),
            modifier = Modifier.height(32.dp).testTag(tag),
        )
    }
}

/** Colour swatches row (8 colours). */
@Composable
fun SwatchRow(selected: RGBAColor?, includeNone: Boolean = false, onPick: (RGBAColor?) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (includeNone) {
            Box(Modifier.size(30.dp).clip(CircleShape).background(Palette.surfaceRaised)
                .border(2.dp, if (selected == null) Color.White else Color.Transparent, CircleShape)
                .clickable { onPick(null) }.testTag("swatch.none"))
        }
        SWATCHES.forEachIndexed { i, c ->
            Box(Modifier.size(30.dp).clip(CircleShape).background(c.compose())
                .border(if (selected == c) 2.5.dp else 1.dp, if (selected == c) Color.White else Palette.hairline, CircleShape)
                .clickable { onPick(c) }.testTag("swatch.$i"))
        }
    }
}

data class Toast(val message: String)

@Composable
fun ToastView(toast: Toast) {
    Text(
        toast.message, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.8f))
            .padding(horizontal = 16.dp, vertical = 10.dp).testTag("toast"),
    )
}
