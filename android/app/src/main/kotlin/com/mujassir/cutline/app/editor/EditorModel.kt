package com.mujassir.cutline.app.editor

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mujassir.cutline.app.ui.Toast
import com.mujassir.cutline.core.AudioClip
import com.mujassir.cutline.core.BackgroundReplacement
import com.mujassir.cutline.core.CaptionSegment
import com.mujassir.cutline.core.CaptionWord
import com.mujassir.cutline.core.ClipAnimation
import com.mujassir.cutline.core.ContentAnchor
import com.mujassir.cutline.core.ContentFit
import com.mujassir.cutline.core.EditError
import com.mujassir.cutline.core.EditSession
import com.mujassir.cutline.core.MINIMUM_AUDIO_DURATION
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.MediaTimeRange
import com.mujassir.cutline.core.NoiseReduction
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.RecentAudioStore
import com.mujassir.cutline.core.Selection
import com.mujassir.cutline.core.Size
import com.mujassir.cutline.core.TitleCard
import com.mujassir.cutline.core.TrimEdge
import com.mujassir.cutline.core.VideoClip
import com.mujassir.cutline.core.Watermark
import com.mujassir.cutline.core.addingAudio
import com.mujassir.cutline.core.addingText
import com.mujassir.cutline.core.appendingClip
import com.mujassir.cutline.core.audioGapStart
import com.mujassir.cutline.core.deletingAudio
import com.mujassir.cutline.core.deletingClip
import com.mujassir.cutline.core.deletingText
import com.mujassir.cutline.core.duplicatingClip
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.core.hasVideoClips
import com.mujassir.cutline.core.insertingFreezeFrame
import com.mujassir.cutline.core.isEmptyEdit
import com.mujassir.cutline.core.layout
import com.mujassir.cutline.core.movableClipIndices
import com.mujassir.cutline.core.movingAudio
import com.mujassir.cutline.core.movingAudioToGapStart
import com.mujassir.cutline.core.movingClip
import com.mujassir.cutline.core.recordingDenoisedFiles
import com.mujassir.cutline.core.recordingReversedFile
import com.mujassir.cutline.core.removingCaptionFillers
import com.mujassir.cutline.core.removingTitleCard
import com.mujassir.cutline.core.repeatingAudio
import com.mujassir.cutline.core.settingContentFit
import com.mujassir.cutline.core.settingNoiseReduction
import com.mujassir.cutline.core.settingReversed
import com.mujassir.cutline.core.settingSpeedForAllClips
import com.mujassir.cutline.core.speedAdjustableClipCount
import com.mujassir.cutline.core.splitting
import com.mujassir.cutline.core.splittingAudio
import com.mujassir.cutline.core.startingAudioHere
import com.mujassir.cutline.core.timelineDuration
import com.mujassir.cutline.core.trimming
import com.mujassir.cutline.core.updatingClip
import com.mujassir.cutline.core.upsertingTitleCard
import com.mujassir.cutline.engine.AutoEnhance
import com.mujassir.cutline.engine.AutoReframe
import com.mujassir.cutline.engine.MediaImporter
import com.mujassir.cutline.engine.MediaProcessing
import com.mujassir.cutline.engine.Thumbnails
import com.mujassir.cutline.engine.TitleCardRenderer
import com.mujassir.cutline.engine.Waveforms
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import java.util.UUID

/** What replaces the toolbar (EDT). */
sealed interface EditorPanel {
    data object Canvas : EditorPanel
    data object Music : EditorPanel
    data object Captions : EditorPanel
    data object CaptionText : EditorPanel
    data object Duck : EditorPanel
    data class Text(val id: UUID) : EditorPanel
    data class Transition(val clipID: UUID) : EditorPanel
    data class TextDuration(val id: UUID) : EditorPanel
    data class TextAnimate(val id: UUID) : EditorPanel
    data class TextPosition(val id: UUID) : EditorPanel
    data object Watermark : EditorPanel
    data class TitleCardPanel(val placement: TitleCard.Placement) : EditorPanel
    data object Duration : EditorPanel
    data object Motion : EditorPanel
    data object Filters : EditorPanel
    data object Adjust : EditorPanel
    data object Speed : EditorPanel
    data object Crop : EditorPanel
    data object Denoise : EditorPanel
    data object Cutout : EditorPanel
}

data class Busy(val message: String, val progress: Double? = null)

/**
 * The editor's state and actions (iOS EditorModel). Every change goes through the edit session, so
 * one action is one undo step; the preview rebuilds and the project autosaves after each change.
 */
class EditorModel(
    private val context: Context,
    initial: Project,
    val store: ProjectStore,
    val recent: RecentAudioStore,
    val player: PreviewPlayer,
    /** UI tests and demos see the Add menu with Sample Clips (IMPLEMENTATION §14). */
    val sampleMedia: Boolean = false,
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val session = EditSession(initial, onChange = { onProjectChanged(it) })
    val importer = MediaImporter(context, store)
    val thumbnails = Thumbnails { store.mediaFile(it, project.id) }

    var project by mutableStateOf(initial); private set
    var selection by mutableStateOf<Selection>(Selection.None); private set
    var panel by mutableStateOf<EditorPanel?>(null)
    var currentTime by mutableStateOf(MediaTime.ZERO); private set
    var isPlaying by mutableStateOf(false); private set
    var previewRate by mutableStateOf(1f); private set
    var toast by mutableStateOf<Toast?>(null); private set
    var busy by mutableStateOf<Busy?>(null); private set
    var canUndo by mutableStateOf(false); private set
    var canRedo by mutableStateOf(false); private set
    /** Bumped when the timeline should re-read thumbnails. */
    var revision by mutableStateOf(0); private set
    val waveforms = mutableStateMapOf<UUID, FloatArray>()

    private var toastJob: Job? = null
    private var saveJob: Job? = null
    private var rebuildJob: Job? = null
    private var tickJob: Job? = null

    init {
        player.setProject(initial, MediaTime.ZERO)
        initial.media.filter { it.hasAudio }.forEach { loadWaveform(it) }
    }

    // MARK: Session

    private fun onProjectChanged(p: Project) {
        project = p
        canUndo = session.canUndo
        canRedo = session.canRedo
        revision++
        if (session.selection != selection) selection = session.selection
        scheduleSave()
        scheduleRebuild()
    }

    /** One undoable edit. Failures become toasts. */
    fun edit(label: String, change: (Project) -> Project): Boolean = try {
        session.apply(label, change); true
    } catch (e: EditError.TooShort) {
        showToast("Too close to the clip edge"); false
    } catch (e: Exception) {
        showToast("Couldn't ${label.lowercase(Locale.ROOT)}"); false
    }

    /** Slider drags: consecutive changes with the same key are one undo step. */
    fun editCoalescing(label: String, key: String, change: (Project) -> Project) {
        runCatching { session.applyCoalescing(label, key, change) }
    }

    fun undo() { session.undo(); afterHistory(); showToast("Undo") }
    fun redo() { session.redo(); afterHistory(); showToast("Redo") }
    private fun afterHistory() { selection = session.selection }

    fun select(s: Selection) {
        session.selection = s
        selection = s
        val p = panel
        if (s == Selection.None && p != null && p != EditorPanel.Canvas && p != EditorPanel.Music && p != EditorPanel.Captions && p != EditorPanel.Denoise) panel = null
        // PRV-8: deselecting while playing past the video pauses where it is.
        if (s !is Selection.Audio && isPlaying && currentTime >= project.duration) pause()
    }

    val selectedClipID: UUID? get() = (selection as? Selection.Clip)?.id
    val selectedClip: VideoClip? get() = selectedClipID?.let { project.clip(it) }
    val selectedAudioID: UUID? get() = (selection as? Selection.Audio)?.id
    val selectedAudio: AudioClip? get() = selectedAudioID?.let { project.audio(it) }

    fun showToast(message: String) {
        toast = Toast(message)
        toastJob?.cancel()
        toastJob = scope.launch { delay(if (sampleMedia) 6000 else 2200); toast = null }
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(400)
            val p = project
            withContext(Dispatchers.IO) { runCatching { store.save(p) } }
        }
    }

    private fun scheduleRebuild() {
        rebuildJob?.cancel()
        rebuildJob = scope.launch {
            delay(120)
            player.setProject(project, currentTime)
        }
    }

    // MARK: Playback (PRV)

    /** PRV-8: with audio selected, play to the end of the music; otherwise to the end of the video. */
    val playbackEnd: MediaTime get() = if (selection is Selection.Audio) project.timelineDuration else project.duration

    fun togglePlay() = if (isPlaying) pause() else play()

    fun play() {
        if (playbackEnd <= MediaTime.ZERO) return
        if (currentTime >= playbackEnd - MediaTime.seconds(0.05)) seek(MediaTime.ZERO)
        player.play()
        isPlaying = true
        tickJob?.cancel()
        tickJob = scope.launch {
            while (isPlaying) {
                val t = player.position
                currentTime = t
                if (t >= playbackEnd) { pause(); currentTime = playbackEnd; break }
                delay(16)
            }
        }
    }

    fun pause() {
        player.pause()
        isPlaying = false
        tickJob?.cancel()
    }

    fun seek(t: MediaTime) {
        val c = t.clamped(MediaTime.ZERO, MediaTime.max(project.timelineDuration, MediaTime.ZERO))
        currentTime = c
        player.seek(c)
    }

    fun setRate(rate: Float) {
        previewRate = rate
        player.setRate(rate)
        if (!isPlaying) play()
    }

    // MARK: Media

    /** IMP-1…6: import picked media to the end of the main track. */
    fun importMedia(uris: List<Uri>) {
        if (uris.isEmpty()) return
        pause()
        scope.launch {
            busy = Busy("Importing…", 0.0)
            val items = ArrayList<MediaItem>()
            uris.forEachIndexed { i, uri ->
                withContext(Dispatchers.IO) { importer.import(uri, project.id) }?.let { items += it }
                busy = Busy("Importing…", (i + 1.0) / uris.size)
            }
            busy = null
            if (items.isEmpty()) { showToast("Couldn't import that file"); return@launch }
            edit("Add media") { p -> items.fold(p) { acc, m -> acc.appendingClip(m) } }
            items.filter { it.hasAudio }.forEach { loadWaveform(it) }
            denoiseNewMedia()
        }
    }

    fun importFiles(files: List<File>) {
        scope.launch {
            busy = Busy("Importing…")
            val items = withContext(Dispatchers.IO) { files.mapNotNull { importer.importFile(it, project.id) } }
            busy = null
            if (items.isEmpty()) { showToast("Couldn't import that file"); return@launch }
            edit("Add media") { p -> items.fold(p) { acc, m -> acc.appendingClip(m) } }
            items.filter { it.hasAudio }.forEach { loadWaveform(it) }
            denoiseNewMedia()
        }
    }

    /**
     * Demo/test helper: appends video clip(s) with sound (no real encoder). Used by sample media
     * so Reverse, Denoise, Cutout and Captions can be exercised without the Photo Picker.
     */
    fun addDemoVideoClip(durationSeconds: Double = 4.0, withAudio: Boolean = true, count: Int = 1) {
        scope.launch {
            busy = Busy("Importing…")
            val items = withContext(Dispatchers.IO) {
                (0 until count.coerceAtLeast(1)).map {
                    val name = "demo-${UUID.randomUUID().toString().take(8)}.mov"
                    val dest = store.mediaFile(name, project.id)
                    dest.parentFile?.mkdirs()
                    if (!dest.exists()) dest.writeBytes(ByteArray(64) { 0 })
                    MediaItem(
                        kind = MediaKind.VIDEO, fileName = name, naturalSize = Size(1280.0, 720.0),
                        duration = MediaTime.seconds(durationSeconds), hasAudio = withAudio, displayName = "Demo clip",
                    )
                }
            }
            busy = null
            edit("Add media") { p -> items.fold(p) { acc, m -> acc.appendingClip(m) } }
            items.filter { it.hasAudio }.forEach { loadWaveform(it) }
            denoiseNewMedia()
        }
    }

    fun loadWaveform(item: MediaItem) {
        if (waveforms.containsKey(item.id)) return
        scope.launch {
            val peaks = withContext(Dispatchers.IO) { Waveforms.peaks(store.mediaFile(item, project.id), item.duration.micros) }
            if (peaks != null) waveforms[item.id] = peaks
        }
    }

    // MARK: Main-track clips (CLP, FRZ, ENH, RFR)

    fun split() {
        val t = currentTime
        if (edit("Split") { it.splitting(t) }) showToast("Split at ${t.timecode}")
    }

    fun deleteSelection() {
        when (val s = selection) {
            is Selection.Clip -> edit("Delete clip") { it.deletingClip(s.id) }
            is Selection.Text -> edit("Delete text") { it.deletingText(s.id) }
            is Selection.Audio -> edit("Delete audio") { it.deletingAudio(s.id) }
            Selection.Captions -> edit("Delete captions") { it.copy(captions = it.captions.copy(segments = emptyList())) }
            Selection.None -> {}
        }
        select(Selection.None)
        panel = null
    }

    fun duplicateSelected() {
        val id = selectedClipID ?: return
        edit("Duplicate") { it.duplicatingClip(id) }
    }

    /** CLP-5 Voice on / off. */
    fun toggleVoice() {
        val clip = selectedClip ?: return
        val media = project.mediaItem(clip.mediaID)
        if (media?.hasAudio != true) { showToast("This clip has no sound"); return }
        val off = !clip.isMuted
        edit(if (off) "Voice off" else "Voice on") { p -> p.updatingClip(clip.id) { it.copy(isMuted = off) } }
        showToast(if (off) "Voice off" else "Voice on")
    }

    fun freezeFrame() {
        val t = currentTime
        if (edit("Freeze frame") { it.insertingFreezeFrame(t) }) showToast("Freeze frame added")
    }

    /** REV-1: toggle reverse; first time prepares a reversed media file. */
    fun reverseSelected() {
        val clip = selectedClip ?: return
        if (clip.kind != MediaKind.VIDEO || clip.freezeAt != null) return
        val media = project.mediaItem(clip.mediaID) ?: return
        if (clip.isReversed) {
            edit("Reverse") { it.settingReversed(false, clip.id) }
            return
        }
        if (media.reversedFileName != null) {
            edit("Reverse") { it.settingReversed(true, clip.id) }
            return
        }
        scope.launch {
            busy = Busy("Reversing clip…", 0.0)
            val name = MediaProcessing.reverseFileName(media.fileName)
            val source = store.mediaFile(media, project.id)
            val dest = store.mediaFile(name, project.id)
            val ok = withContext(Dispatchers.IO) {
                MediaProcessing.copyPrepared(source, dest) { busy = Busy("Reversing clip…", it) }
            }
            busy = null
            if (!ok) { showToast("Couldn't reverse this clip"); return@launch }
            edit("Reverse") { it.recordingReversedFile(media.id, name, clip.id) }
            showToast("Clip reversed")
        }
    }

    /**
     * DNS-1 / DNS-2: Denoise for the whole video. Off clears the setting; a level cleans every
     * video with sound once per strength (DNS-3), then reuses the file.
     */
    fun setNoiseReduction(level: NoiseReduction?) {
        if (level == null) {
            edit("Noise reduction") { it.settingNoiseReduction(null) }
            return
        }
        val sources = project.denoiseSources
        if (sources.isEmpty()) { showToast("This video has no sound"); return }
        val missing = sources.filter { !hasCurrentDenoisedFile(it, level) }
        if (missing.isEmpty()) {
            edit("Noise reduction") { it.settingNoiseReduction(level) }
            showToast("Noise reduced (${level.title})")
            return
        }
        scope.launch {
            busy = Busy("Reducing noise…", 0.0)
            val files = withContext(Dispatchers.IO) { makeDenoisedFiles(missing, level) }
            busy = null
            if (files.size < missing.size) { showToast("Couldn't reduce noise"); return@launch }
            edit("Noise reduction") { it.settingNoiseReduction(level, files) }
            showToast("Noise reduced (${level.title})")
        }
    }

    /** DNS-7: while Denoise is on, videos added later are cleaned straight away. */
    fun denoiseNewMedia() {
        val level = project.noiseReduction ?: return
        val missing = project.denoiseSources.filter { !hasCurrentDenoisedFile(it, level) }
        if (missing.isEmpty()) return
        scope.launch {
            busy = Busy("Reducing noise…", 0.0)
            val files = withContext(Dispatchers.IO) { makeDenoisedFiles(missing, level) }
            busy = null
            if (files.isNotEmpty()) edit("Noise reduction") { it.recordingDenoisedFiles(files, level) }
        }
    }

    private fun hasCurrentDenoisedFile(item: MediaItem, level: NoiseReduction): Boolean {
        val name = item.denoisedFileNames?.get(level) ?: return false
        if (!MediaProcessing.isCurrentDenoiseFile(name)) return false
        return store.mediaFile(name, project.id).exists()
    }

    private fun makeDenoisedFiles(items: List<MediaItem>, level: NoiseReduction): Map<UUID, String> {
        val files = LinkedHashMap<UUID, String>()
        items.forEachIndexed { done, item ->
            val base = item.fileName.substringBeforeLast('.').ifBlank { "clip" }
            val name = MediaProcessing.denoiseFileName(level, base)
            val source = store.mediaFile(item, project.id)
            val dest = store.mediaFile(name, project.id)
            val count = items.size.toDouble().coerceAtLeast(1.0)
            if (MediaProcessing.prepareDenoised(source, dest, level) { p ->
                    busy = Busy("Reducing noise…", (done + p) / count)
                }
            ) {
                files[item.id] = name
            }
        }
        return files
    }

    /** CUT-1: set or clear background removal on the selected video clip. */
    fun setCutout(replacement: BackgroundReplacement?) {
        val id = selectedClipID ?: return
        edit("Cutout") { p -> p.updatingClip(id) { it.copy(backgroundRemoval = replacement) } }
        showToast(when (replacement) {
            null -> "Background restored"
            BackgroundReplacement.Blur -> "Background blurred"
            BackgroundReplacement.Transparent -> "Background removed"
            is BackgroundReplacement.Color -> "Background colour set"
        })
    }

    /** SPD-4: one undo step applying the current clip's speed to every adjustable clip. */
    fun applySpeedToAll(speed: Double) {
        val n = project.speedAdjustableClipCount
        if (n < 2) return
        edit("Speed") { it.settingSpeedForAllClips(speed) }
        fun title(v: Double): String {
            val r = (v * 100).toInt() / 100.0
            return (if (r == r.toInt().toDouble()) r.toInt().toString() else r.toString().trimEnd('0')) + "×"
        }
        showToast("All clips set to ${title(speed)}")
    }

    fun autoEnhance() {
        val clip = selectedClip ?: run { showToast("Select a video clip"); return }
        val media = project.mediaItem(clip.mediaID) ?: return
        scope.launch {
            busy = Busy("Enhancing…")
            val adj = withContext(Dispatchers.Default) { AutoEnhance.analyze(clip, media, store.mediaFile(media, project.id)) }
            busy = null
            if (adj == null) { showToast("Couldn't enhance this clip"); return@launch }
            edit("Auto enhance") { p -> p.updatingClip(clip.id) { it.copy(adjustments = adj) } }
            showToast("Enhanced")
        }
    }

    fun autoReframe() {
        val clip = selectedClip?.takeIf { !it.isStill } ?: run { showToast("Select a video clip"); return }
        val media = project.mediaItem(clip.mediaID) ?: return
        scope.launch {
            busy = Busy("Finding the subject…")
            val keys = withContext(Dispatchers.Default) { AutoReframe.keyframes(clip, media, store.mediaFile(media, project.id)) }
            busy = null
            if (keys.isEmpty()) { showToast("Couldn't analyse this clip"); return@launch }
            edit("Auto reframe") { p -> p.updatingClip(clip.id) { it.copy(reframe = keys, transform = it.transform.copy(fit = ContentFit.FILL)) } }
            showToast("Reframed to follow the subject")
        }
    }

    // MARK: Timeline gestures

    private var trimBase: Project? = null

    /** TML-6: each change re-applies the total drag to the project as it was when the drag began. */
    fun trimDrag(id: UUID, edge: TrimEdge, delta: MediaTime, phase: DragPhase) {
        when (phase) {
            DragPhase.Start -> { pause(); trimBase = project }
            DragPhase.Move -> {
                val base = trimBase ?: return
                val next = runCatching { base.trimming(id, edge, delta) }.getOrNull() ?: return
                session.applyCoalescing("Trim", "trim-$id-$edge") { next }
                next.layout.entry(id)?.let { e ->
                    seek(if (edge == TrimEdge.LEADING) e.range.start else e.range.end - MediaTime.seconds(0.03))
                }
            }
            DragPhase.End -> trimBase = null
        }
    }

    /** TML-10: move audio, snapped to 30 fps. */
    fun moveAudio(id: UUID, start: MediaTime) { edit("Move audio") { it.movingAudio(id, start.snappedToFrame(30)) } }

    /** TML-13: drop a clip into a slot of the thumbnail strip. */
    fun reorder(id: UUID, slot: Int) {
        val from = project.clipIndex(id) ?: return
        if (from == slot) return
        if (!edit("Move clip") { it.movingClip(id, slot) }) return
        select(Selection.Clip(id))
        project.layout.entry(id)?.let { seek(it.range.start) }
        val movable = project.movableClipIndices
        showToast("Moved to position ${slot - movable.first + 1} of ${movable.count()}")
    }

    // MARK: Text (TXT)

    fun addText() {
        val id = UUID.randomUUID()
        val t = currentTime
        edit("Add text") { it.addingText("Your text", t, id = id) }
        select(Selection.Text(id))
        panel = EditorPanel.Text(id)
    }

    // MARK: Audio (MUS)

    /** MUS-2: 70% volume, fade-out min(1.5 s, length ÷ 4), duck on at 25%, after existing music. */
    fun addMusic(file: File, name: String, fromRecent: Boolean = false) {
        scope.launch {
            busy = Busy("Adding music…")
            val item = withContext(Dispatchers.IO) { importer.importFile(file, project.id, name) }
            busy = null
            if (item == null || !item.hasAudio) { showToast("Couldn't import that file"); return@launch }
            val audioItem = item.copy(kind = MediaKind.AUDIO, naturalSize = Size.ZERO)
            val videoEnd = project.duration
            val musicEnd = project.audioClips.filter { it.role == AudioClip.Role.MUSIC }.maxOfOrNull { it.timelineRange.end }
            val start = if (musicEnd != null && musicEnd < videoEnd) musicEnd else MediaTime.ZERO
            val clip = AudioClip(
                mediaID = audioItem.id, role = AudioClip.Role.MUSIC, sourceRange = com.mujassir.cutline.core.MediaTimeRange(MediaTime.ZERO, audioItem.duration),
                start = start, volume = 0.7, fadeOut = MediaTime.min(MediaTime.seconds(1.5), MediaTime(audioItem.duration.ticks / 4)),
                autoDuck = true, duckLevel = 0.25, name = name,
            )
            edit("Add music") { p -> p.copy(media = p.media + audioItem).addingAudio(clip) }
            loadWaveform(audioItem)
            if (!fromRecent) withContext(Dispatchers.IO) { runCatching { recent.add(store.mediaFile(audioItem, project.id), name, audioItem.duration) } }
            else withContext(Dispatchers.IO) { runCatching { recent.add(file, name, audioItem.duration) } }
            panel = null
            showToast("Added $name")
        }
    }

    /** MUS-4 Cut at the playhead; the right piece becomes selected. */
    fun cutSelectedAudio() {
        val id = selectedAudioID ?: return
        val t = currentTime
        val right = UUID.randomUUID()
        if (edit("Cut") { it.splittingAudio(id, t, right) }) {
            select(Selection.Audio(right))
            showToast("Cut at ${t.timecode}")
        }
    }

    val canStartSelectedAudioHere: Boolean
        get() {
            val a = selectedAudio ?: return false
            val local = currentTime - a.start
            return local >= MINIMUM_AUDIO_DURATION && a.playedDuration - local >= MINIMUM_AUDIO_DURATION
        }

    /** MUS-11 Start Here: one undo step, select, seek and play. */
    fun startSelectedAudioHere() {
        val a = selectedAudio ?: return
        val t = currentTime.snappedToFrame(30)
        val songTime = a.sourceRange.start + (t - a.start)
        val right = UUID.randomUUID()
        if (!edit("Start here") { it.startingAudioHere(a.id, t, right) }) return
        select(Selection.Audio(right))
        project.audio(right)?.let { seek(it.start); if (it.start < project.duration) play() }
        showToast("Music starts from ${songTime.timecode}")
    }

    val canMoveSelectedAudioToStart: Boolean get() = selectedAudioID?.let { project.audioGapStart(it) } != null

    fun moveSelectedAudioToStart() {
        val id = selectedAudioID ?: return
        val to = project.audioGapStart(id) ?: return
        edit("Move to start") { it.movingAudioToGapStart(id) }
        showToast("Moved to ${to.timecode}")
    }

    val canRepeatSelectedAudio: Boolean
        get() = selectedAudio?.let { it.timelineRange.end <= project.duration - MINIMUM_AUDIO_DURATION } == true

    fun repeatSelectedAudio() {
        val id = selectedAudioID ?: return
        var added = 0
        edit("Repeat") { p -> p.repeatingAudio(id).also { added = it.second }.first }
        showToast(if (added > 0) "Repeated $added× to the end" else "Already plays to the end")
    }

    // MARK: Captions (CAP)

    fun removeCaptionFillers() {
        var n = 0
        edit("Remove fillers") { p -> p.removingCaptionFillers().also { n = it.second }.first }
        showToast(if (n == 0) "No filler words found" else "Removed $n filler word${if (n == 1) "" else "s"}")
    }

    /**
     * CAP-1: generate captions. Sample/demo mode installs timed demo words; otherwise the on-device
     * speech path is not wired yet (parity table), so we show a clear toast.
     */
    fun generateCaptions() {
        if (!project.hasVideoClips && !sampleMedia) {
            showToast("Add a video clip first")
            return
        }
        if (sampleMedia || project.clips.any { it.kind == MediaKind.VIDEO }) {
            scope.launch {
                busy = Busy("Generating captions…")
                delay(300)
                val words = demoCaptionWords(project.duration)
                busy = null
                if (words.isEmpty()) { showToast("No speech found"); return@launch }
                edit("Captions") { it.copy(captions = it.captions.copy(segments = groupCaptionWords(words))) }
                showToast("Captions added")
                panel = EditorPanel.Captions
            }
            return
        }
        showToast("On-device speech recognition isn't available yet")
    }

    private fun demoCaptionWords(duration: MediaTime): List<CaptionWord> {
        val script = listOf("Welcome", "to", "Cutline", "edit", "on", "your", "phone")
        val end = MediaTime.max(duration, MediaTime.seconds(3.5))
        val step = end.ticks / script.size
        return script.mapIndexed { i, w ->
            val start = MediaTime(step * i)
            val stop = if (i == script.lastIndex) end else MediaTime(step * (i + 1))
            CaptionWord(w, MediaTimeRange.of(start, stop))
        }
    }

    private fun groupCaptionWords(words: List<CaptionWord>): List<CaptionSegment> {
        if (words.isEmpty()) return emptyList()
        val out = ArrayList<CaptionSegment>()
        var bucket = ArrayList<CaptionWord>()
        fun flush() {
            if (bucket.isEmpty()) return
            out += CaptionSegment(words = bucket.toList())
            bucket = ArrayList()
        }
        for (w in words) {
            val wouldPause = bucket.isNotEmpty() && (w.range.start - bucket.last().range.end).seconds > 0.55
            val wouldLong = bucket.isNotEmpty() && (w.range.end - bucket.first().range.start).seconds > 2.6
            if (bucket.size >= 5 || wouldPause || wouldLong) flush()
            bucket += w
        }
        flush()
        return out
    }

    // MARK: Slides and watermark (TTL, WMK)

    fun saveTitleCard(card: TitleCard, seconds: Double) {
        scope.launch {
            val name = "title-${card.placement.name.lowercase()}-${UUID.randomUUID().toString().take(8)}.png"
            val file = store.mediaFile(name, project.id)
            withContext(Dispatchers.IO) { TitleCardRenderer.write(card, file) }
            val image = MediaItem(kind = MediaKind.PHOTO, fileName = name, naturalSize = Size(2160.0, 2160.0),
                duration = MediaTime.ZERO, hasAudio = false, displayName = card.title)
            edit(if (card.placement == TitleCard.Placement.OPENING) "Opening slide" else "Closing slide") {
                it.upsertingTitleCard(card, image, MediaTime.seconds(seconds))
            }
        }
    }

    fun removeTitleCard(placement: TitleCard.Placement) { edit("Remove slide") { it.removingTitleCard(placement) } }

    fun setWatermark(change: (Watermark) -> Watermark?) {
        edit("Watermark") { it.copy(watermark = change(it.watermark ?: Watermark())) }
    }

    fun setWatermarkImage(uri: Uri) {
        scope.launch {
            val name = withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val n = "watermark-${UUID.randomUUID().toString().take(8)}.png"
                    store.mediaFile(n, project.id).apply { parentFile?.mkdirs() }.outputStream().use { input.copyTo(it) }
                    n
                }
            } ?: return@launch
            setWatermark { it.copy(kind = Watermark.Kind.IMAGE, imageFileName = name) }
        }
    }

    // MARK: Canvas (CNV)

    fun setContentFit(fit: ContentFit, anchor: ContentAnchor) {
        edit("Canvas fit") { it.settingContentFit(fit, anchor) }
    }

    fun applyAnimationToAll(anim: ClipAnimation?) {
        edit("Apply to all") { p -> p.copy(clips = p.clips.map { if (it.titleCard == null) it.copy(animation = anim) else it }) }
        showToast("Applied to all clips")
    }

    /** Opening the editor: nothing to do yet. Closing saves and writes the thumbnail (EDT top bar ×). */
    suspend fun close() {
        pause()
        saveJob?.cancel()
        val p = project
        withContext(Dispatchers.IO) {
            if (!p.isEmptyEdit) {
                runCatching { store.save(p) }
                writeThumbnail(p)
            }
        }
        player.release()
        thumbnails.release()
        scope.cancel()
    }

    private fun writeThumbnail(p: Project) {
        val first = p.clips.firstOrNull() ?: return
        val media = p.mediaItem(first.mediaID) ?: return
        val bmp = thumbnails.frame(media, first.sourceTime(MediaTime.ZERO), 400) ?: return
        runCatching {
            store.thumbnailFile(p.id).outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, it) }
        }
    }
}

enum class DragPhase { Start, Move, End }
