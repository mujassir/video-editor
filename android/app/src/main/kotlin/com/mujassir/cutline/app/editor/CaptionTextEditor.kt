package com.mujassir.cutline.app.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mujassir.cutline.app.ui.Palette
import com.mujassir.cutline.core.retimeCaption
import kotlinx.coroutines.delay
import java.util.UUID

/** CAP-5: full-screen caption editor. Typing only changes a draft; Done saves once (one undo step). */
@Composable
fun CaptionTextEditor(model: EditorModel) {
    val segments = model.project.captions.segments
    val drafts = remember { mutableStateMapOf<UUID, String>() }
    val start = remember {
        val t = model.currentTime
        segments.indexOfFirst { t >= it.range.start && t < it.range.end }.takeIf { it >= 0 }
            ?: segments.indexOfLast { it.range.start <= t }.takeIf { it >= 0 } ?: 0
    }
    var focused by remember { mutableIntStateOf(start) }
    val requesters = remember(segments.size) { List(segments.size) { FocusRequester() } }
    val list = rememberLazyListState()
    LaunchedEffect(Unit) {
        list.scrollToItem(start)
        delay(450)
        runCatching { requesters.getOrNull(start)?.requestFocus() }
    }
    fun save() {
        val changed = segments.filter { s -> drafts[s.id]?.let { it != s.text } == true }
        if (changed.isNotEmpty()) model.edit("Edit captions") { p ->
            p.copy(captions = p.captions.copy(segments = p.captions.segments.map { s ->
                drafts[s.id]?.takeIf { it != s.text }?.let { s.copy(words = retimeCaption(it, s)) } ?: s
            }.filter { it.words.isNotEmpty() }))
        }
        model.panel = null
    }
    Box(Modifier.fillMaxSize().background(Palette.background), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.widthIn(max = 720.dp).fillMaxSize().imePadding()) {
            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Cancel", color = Color.White, modifier = Modifier.clickable { model.panel = null }.testTag("captionEditor.cancel"))
                Text("Edit Captions", color = Color.White, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
                Text("Done", color = Palette.accent, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable { save() }.testTag("captionEditor.done"))
            }
            LazyColumn(state = list, verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(horizontal = 16.dp)) {
                itemsIndexed(segments, key = { _, s -> s.id }) { i, s ->
                    Column {
                        Text("${s.range.start.timecode} – ${s.range.end.timecode}", fontSize = 12.sp,
                            color = if (focused == i) Palette.accent else Palette.secondaryText,
                            modifier = Modifier.clickable { model.seek(s.range.start) })
                        OutlinedTextField(drafts[s.id] ?: s.text, { drafts[s.id] = it }, modifier = Modifier.fillMaxWidth()
                            .focusRequester(requesters[i]).onFocusChanged { f -> if (f.isFocused) focused = i }.testTag("caption.field.$i"),
                            keyboardOptions = KeyboardOptions(imeAction = if (i < segments.lastIndex) ImeAction.Next else ImeAction.Done),
                            keyboardActions = KeyboardActions(onNext = { runCatching { requesters[i + 1].requestFocus() } }, onDone = { save() }),
                            colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Palette.accent))
                    }
                }
            }
        }
    }
}
