package com.mujassir.cutline.app.library

import android.graphics.BitmapFactory
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mujassir.cutline.app.editor.WIDE_MIN_WIDTH
import com.mujassir.cutline.app.ui.Palette
import com.mujassir.cutline.core.AppleDate
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.duration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** LIB-1…5 and LAY-6. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(app: LibraryModel, onOpen: (Project) -> Unit, onCreate: () -> Unit) {
    var renaming by remember { mutableStateOf<Project?>(null) }
    var menuFor by remember { mutableStateOf<Project?>(null) }
    val tablet = LocalConfiguration.current.smallestScreenWidthDp >= 600
    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.background).statusBarsPadding().navigationBarsPadding(), contentAlignment = Alignment.TopCenter) {
        val wide = maxWidth >= WIDE_MIN_WIDTH
        LazyVerticalGrid(
            columns = if (wide) GridCells.Adaptive(220.dp) else GridCells.Fixed(2),
            modifier = Modifier.widthIn(max = if (wide) 1200.dp else maxWidth).fillMaxSize().padding(horizontal = 18.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Text("Cutline", color = Color.White, fontSize = 32.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 16.dp))
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth()) { NewProjectCard(Modifier.widthIn(max = if (wide) 720.dp else 2000.dp), onCreate) }
            }
            if (app.projects.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) { Text("Recent", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold) }
                items(app.projects, key = { it.id }) { p ->
                    Box {
                        ProjectCard(p, app.thumbnail(p), Modifier.combinedClickable(onClick = { onOpen(p) }, onLongClick = { menuFor = p }))
                        DropdownMenu(menuFor == p, onDismissRequest = { menuFor = null }) {
                            DropdownMenuItem(text = { Text("Rename") }, onClick = { menuFor = null; renaming = p })
                            DropdownMenuItem(text = { Text("Duplicate") }, onClick = { menuFor = null; app.duplicate(p) })
                            DropdownMenuItem(text = { Text("Delete", color = Palette.accent) }, onClick = { menuFor = null; app.delete(p) })
                        }
                    }
                }
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(Modifier.padding(vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Lock, null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(10.dp))
                    // LIB-5 / LAY-8: the device's own word.
                    Text("Everything runs on your ${if (tablet) "tablet" else "phone"}. No account, no uploads, no watermark.",
                        color = Palette.secondaryText, fontSize = 13.sp, modifier = Modifier.testTag("library.privacy"))
                }
            }
        }
    }
    renaming?.let { p ->
        var name by remember(p.id) { mutableStateOf(p.name) }
        AlertDialog(onDismissRequest = { renaming = null }, title = { Text("Rename project") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true, modifier = Modifier.testTag("rename.field")) },
            confirmButton = { TextButton({ app.rename(p, name); renaming = null }) { Text("Save") } },
            dismissButton = { TextButton({ renaming = null }) { Text("Cancel") } })
    }
}

@Composable
private fun NewProjectCard(modifier: Modifier, onCreate: () -> Unit) {
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
        .background(Brush.linearGradient(listOf(Palette.accent, Color(0.55f, 0.2f, 0.95f))))
        .combinedClickableCompat(onCreate).padding(18.dp).testTag("projects.new"), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(56.dp).clip(RoundedCornerShape(14.dp)).background(Color.White.copy(alpha = 0.2f)), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Add, null, tint = Color.White, modifier = Modifier.size(30.dp))
        }
        Spacer(Modifier.width(16.dp))
        Column {
            Text("New Project", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text("Edit videos and photos with on-device AI", color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(onClick: () -> Unit) = this.combinedClickable(onClick = onClick)

@Composable
private fun ProjectCard(p: Project, thumb: File, modifier: Modifier) {
    val img by produceState<ImageBitmap?>(null, p.modifiedAt) {
        value = withContext(Dispatchers.IO) { runCatching { BitmapFactory.decodeFile(thumb.absolutePath)?.asImageBitmap() }.getOrNull() }
    }
    Column(modifier.testTag("project.card")) {
        Box(Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(14.dp)).background(Palette.surfaceRaised)) {
            img?.let { Image(it, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                ?: Icon(Icons.Default.Movie, null, tint = Palette.secondaryText, modifier = Modifier.align(Alignment.Center))
            Text(p.duration.timecode, color = Color.White, fontSize = 11.sp, modifier = Modifier.align(Alignment.BottomEnd).padding(6.dp)
                .clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 6.dp, vertical = 2.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(p.name, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(relative(p.modifiedAt), color = Palette.secondaryText, fontSize = 12.sp)
    }
}

private fun relative(apple: Double): String {
    val s = ((System.currentTimeMillis() - AppleDate.toEpochMillis(apple)) / 1000).coerceAtLeast(0)
    return when {
        s < 60 -> "now"; s < 3600 -> "${s / 60} min"; s < 86_400 -> "${s / 3600} h"; else -> "${s / 86_400} d"
    }
}
