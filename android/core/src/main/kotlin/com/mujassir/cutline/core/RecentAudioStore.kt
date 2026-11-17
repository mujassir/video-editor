@file:UseSerializers(UUIDSerializer::class)

package com.mujassir.cutline.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt

/** `recent.json` dates are ISO 8601 (unlike project.json). */
object Iso8601Serializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Iso8601", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) =
        encoder.encodeString(DateTimeFormatter.ISO_INSTANT.format(value.truncatedTo(ChronoUnit.SECONDS)))
    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())
}

/**
 * The 5 audio tracks used most recently in any project (MUS-10), with the app's own copy of each,
 * so a recent track survives its project being deleted.
 */
class RecentAudioStore(val root: File, private val clock: () -> Instant = Instant::now) {
    @Serializable
    data class Entry(
        val id: UUID = UUID.randomUUID(),
        val name: String,
        val fileName: String,
        val duration: MediaTime,
        @Serializable(with = Iso8601Serializer::class) val usedAt: Instant,
    ) {
        /** Same track: same name (any case) and length to 0.1 s. */
        val key get() = "${name.lowercase(Locale.ROOT)}|${(duration.seconds * 10).roundToInt()}"
    }

    companion object { const val LIMIT = 5 }

    init { root.mkdirs() }

    private val index = File(root, "recent.json")
    fun file(entry: Entry) = File(root, entry.fileName)

    /** Newest first; entries whose file is missing are dropped. */
    @get:Synchronized
    val entries: List<Entry> get() = load()

    /** Records a track as just used. The file is copied unless it's already this store's copy. */
    @Synchronized
    fun add(file: File, name: String, duration: MediaTime): List<Entry> {
        val list = load().toMutableList()
        var entry = Entry(name = name, fileName = "", duration = duration, usedAt = clock())
        val i = list.indexOfFirst { it.key == entry.key }
        if (i >= 0) {
            entry = list.removeAt(i).copy(usedAt = clock())
        } else {
            val ext = file.extension.ifEmpty { "m4a" }
            entry = entry.copy(fileName = "${entry.id.toString().uppercase(Locale.ROOT)}.$ext")
            file.copyTo(file(entry), overwrite = true)
        }
        list.add(0, entry)
        list.drop(LIMIT).forEach { file(it).delete() }
        val kept = list.take(LIMIT)
        save(kept)
        return kept
    }

    @Synchronized
    fun remove(id: UUID) {
        val list = load().toMutableList()
        val i = list.indexOfFirst { it.id == id }
        if (i < 0) return
        file(list[i]).delete()
        list.removeAt(i)
        save(list)
    }

    private val serializer = ListSerializer(Entry.serializer())

    private fun load(): List<Entry> {
        if (!index.exists()) return emptyList()
        val list = runCatching { ProjectJson.decodeFromString(serializer, index.readText()) }.getOrDefault(emptyList())
        return list.filter { file(it).exists() }
    }

    private fun save(list: List<Entry>) =
        ProjectStore.writeAtomically(index, ProjectJsonPretty.encodeToString(serializer, list).toByteArray())
}
