package com.mujassir.cutline.core

import java.io.File
import java.io.InputStream
import java.util.Locale
import java.util.UUID

/**
 * Projects on disk (IMPLEMENTATION §4.1):
 *
 *     <root>/<uuid>/project.json, thumbnail.jpg, Media/, Cache/
 *
 * Writes go to a temporary file that is then renamed, so a crash can't corrupt a project.
 */
class ProjectStore(val root: File) {
    init { root.mkdirs() }

    fun directory(id: UUID) = File(root, id.toString().uppercase(Locale.ROOT))
    fun mediaDirectory(id: UUID) = File(directory(id), "Media")
    fun cacheDirectory(id: UUID) = File(directory(id), "Cache")
    fun thumbnailFile(id: UUID) = File(directory(id), "thumbnail.jpg")
    fun mediaFile(item: MediaItem, projectID: UUID) = File(mediaDirectory(projectID), item.fileName)
    fun mediaFile(fileName: String, projectID: UUID) = File(mediaDirectory(projectID), fileName)
    private fun projectFile(id: UUID) = File(directory(id), "project.json")

    fun create(name: String): Project {
        val project = Project(name = name)
        mediaDirectory(project.id).mkdirs()
        save(project)
        return project
    }

    fun save(project: Project) {
        val dir = directory(project.id)
        dir.mkdirs()
        writeAtomically(projectFile(project.id), project.encode().toByteArray())
    }

    fun load(id: UUID): Project = decodeProject(projectFile(id).readText())

    /** All readable projects, most recently modified first. */
    fun listProjects(): List<Project> =
        (root.listFiles() ?: emptyArray()).mapNotNull { dir ->
            val id = runCatching { UUID.fromString(dir.name) }.getOrNull() ?: return@mapNotNull null
            runCatching { load(id) }.getOrNull()
        }.sortedByDescending { it.modifiedAt }

    fun delete(id: UUID) { directory(id).deleteRecursively() }

    /** LIB-3: copies the folder, new id, " Copy" added, both dates now. */
    fun duplicate(id: UUID): Project {
        val original = load(id)
        val now = AppleDate.now()
        val copy = original.copy(id = UUID.randomUUID(), name = original.name + " Copy", createdAt = now, modifiedAt = now)
        directory(id).copyRecursively(directory(copy.id), overwrite = true)
        save(copy)
        return copy
    }

    fun rename(id: UUID, name: String): Project {
        val p = load(id).copy(name = name, modifiedAt = AppleDate.now())
        save(p)
        return p
    }

    /** Copies media into the project as `<new UUID>.<ext in lower case>` (mov if none). Returns the name. */
    fun importStream(input: InputStream, extension: String?, projectID: UUID): String {
        val dir = mediaDirectory(projectID)
        dir.mkdirs()
        val ext = extension?.takeIf { it.isNotBlank() }?.lowercase(Locale.ROOT) ?: "mov"
        val name = "${UUID.randomUUID().toString().uppercase(Locale.ROOT)}.$ext"
        File(dir, name).outputStream().use { out -> input.copyTo(out) }
        return name
    }

    companion object {
        fun writeAtomically(target: File, bytes: ByteArray) {
            val tmp = File(target.parentFile, target.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(target)) {
                target.delete()
                if (!tmp.renameTo(target)) { target.writeBytes(bytes); tmp.delete() }
            }
        }
    }
}
