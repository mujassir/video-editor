package com.mujassir.cutline.core

import java.util.UUID

/** What the toolbar acts on (EDT). */
sealed interface Selection {
    data object None : Selection
    data class Clip(val id: UUID) : Selection
    data class Text(val id: UUID) : Selection
    data class Audio(val id: UUID) : Selection
    data object Captions : Selection
}

/**
 * The project being edited plus its undo / redo history (IMPLEMENTATION §5). Each history entry is
 * a full snapshot (projects are small, immutable values), so undo can't drift out of sync.
 */
class EditSession(
    initial: Project,
    val historyLimit: Int = 200,
    private val onChange: (Project) -> Unit = {},
    private val clock: () -> Double = AppleDate::now,
) {
    data class Entry(val label: String, val project: Project)

    var project: Project = initial
        private set
    private val undoStack = ArrayList<Entry>()
    private val redoStack = ArrayList<Entry>()
    var selection: Selection = Selection.None
    /** Incremented on every change; the player watches it to rebuild. */
    var revision: Int = 0
        private set
    private var lastCoalescingKey: Any? = null

    val canUndo get() = undoStack.isNotEmpty()
    val canRedo get() = redoStack.isNotEmpty()
    val undoLabel get() = undoStack.lastOrNull()?.label
    val redoLabel get() = redoStack.lastOrNull()?.label

    /** One edit = one undo step. A throwing edit leaves everything unchanged. Music is refitted. */
    fun apply(label: String, edit: (Project) -> Project) {
        val next = edit(project).refittingMusic()
        commit(label, next)
    }

    /** Continuous changes (slider drags) with the same key merge into one step. */
    fun applyCoalescing(label: String, key: Any, edit: (Project) -> Project) {
        val next = edit(project).refittingMusic()
        if (lastCoalescingKey == key && undoStack.isNotEmpty()) {
            redoStack.clear()
            setProject(next)
        } else {
            commit(label, next)
            lastCoalescingKey = key
        }
    }

    private fun commit(label: String, next: Project) {
        if (next == project) return
        undoStack += Entry(label, project)
        if (undoStack.size > historyLimit) undoStack.subList(0, undoStack.size - historyLimit).clear()
        redoStack.clear()
        lastCoalescingKey = null
        setProject(next)
    }

    fun undo() {
        val entry = undoStack.removeLastOrNull() ?: return
        redoStack += Entry(entry.label, project)
        lastCoalescingKey = null
        setProject(entry.project)
    }

    fun redo() {
        val entry = redoStack.removeLastOrNull() ?: return
        undoStack += Entry(entry.label, project)
        lastCoalescingKey = null
        setProject(entry.project)
    }

    /** Replaces the project without history (after loading, or a template build). */
    fun replaceWithoutHistory(p: Project) = setProject(p)

    private fun setProject(next: Project) {
        project = next.copy(modifiedAt = clock())
        revision++
        validateSelection()
        onChange(project)
    }

    private fun validateSelection() {
        val s = selection
        val gone = when (s) {
            is Selection.Clip -> project.clipIndex(s.id) == null
            is Selection.Text -> project.text(s.id) == null
            is Selection.Audio -> project.audio(s.id) == null
            else -> false
        }
        if (gone) selection = Selection.None
    }

    val selectedClip: VideoClip? get() = (selection as? Selection.Clip)?.let { project.clip(it.id) }
}
