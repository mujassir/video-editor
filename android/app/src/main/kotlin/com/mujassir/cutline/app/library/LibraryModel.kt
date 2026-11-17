package com.mujassir.cutline.app.library

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.isEmptyEdit
import java.io.File

/** The project library (LIB). */
class LibraryModel(val store: ProjectStore) {
    var projects by mutableStateOf<List<Project>>(emptyList()); private set

    init {
        // LIB-4: empty projects are deleted on app start.
        store.listProjects().filter { it.isEmptyEdit }.forEach { store.delete(it.id) }
        reload()
    }

    fun reload() { projects = store.listProjects() }

    /** LIB-1: `Project N`, N = number of projects + 1. */
    fun create(): Project = store.create("Project ${projects.size + 1}").also { reload() }

    fun rename(p: Project, name: String) { store.rename(p.id, name); reload() }
    fun duplicate(p: Project) { store.duplicate(p.id); reload() }
    fun delete(p: Project) { store.delete(p.id); reload() }
    fun thumbnail(p: Project): File = store.thumbnailFile(p.id)
}
