package com.mujassir.cutline.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Locale
import java.util.UUID

/**
 * The project file encoding (IMPLEMENTATION §4.2–4.3):
 * - every non-optional field is written (`encodeDefaults`), because iOS fails on missing keys;
 * - optional fields set to nothing are left out (`explicitNulls = false`);
 * - unknown keys are ignored, so newer files still open.
 */
val ProjectJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
}

val ProjectJsonPretty = Json(ProjectJson) { prettyPrint = true }

fun Project.encode(): String = ProjectJson.encodeToString(Project.serializer(), this)
fun decodeProject(text: String): Project = ProjectJson.decodeFromString(Project.serializer(), text)

/** UUIDs are upper-case strings. */
object UUIDSerializer : KSerializer<UUID> {
    override val descriptor = PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: UUID) = encoder.encodeString(value.toString().uppercase(Locale.ROOT))
    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
}

/** `CGSize` is a two-number array `[width, height]`. */
object SizeSerializer : KSerializer<Size> {
    private val list = ListSerializer(Double.serializer())
    override val descriptor: SerialDescriptor = list.descriptor
    override fun serialize(encoder: Encoder, value: Size) = list.serialize(encoder, listOf(value.width, value.height))
    override fun deserialize(decoder: Decoder): Size {
        val v = list.deserialize(decoder)
        if (v.size != 2) throw SerializationException("size must be [w, h]")
        return Size(v[0], v[1])
    }
}

/** Swift enum with associated values: `{"blur":{}}` or `{"color":{"_0":{…}}}`. */
private fun caseObject(name: String, value: JsonElement? = null) = buildJsonObject {
    put(name, if (value == null) JsonObject(emptyMap()) else buildJsonObject { put("_0", value) })
}

private fun Decoder.json(): Pair<Json, JsonObject> {
    val d = this as? JsonDecoder ?: throw SerializationException("JSON only")
    return d.json to d.decodeJsonElement().jsonObject
}

object CanvasBackgroundSerializer : KSerializer<CanvasBackground> {
    override val descriptor = buildClassSerialDescriptor("CanvasBackground")
    override fun serialize(encoder: Encoder, value: CanvasBackground) {
        val e = encoder as JsonEncoder
        e.encodeJsonElement(
            when (value) {
                CanvasBackground.Blur -> caseObject("blur")
                is CanvasBackground.Color -> caseObject("color", e.json.encodeToJsonElement(RGBAColor.serializer(), value.color))
            }
        )
    }

    override fun deserialize(decoder: Decoder): CanvasBackground {
        val (json, obj) = decoder.json()
        obj["color"]?.let { return CanvasBackground.Color(json.decodeFromJsonElement(it.jsonObject.getValue("_0"))) }
        return CanvasBackground.Blur
    }
}

object BackgroundReplacementSerializer : KSerializer<BackgroundReplacement> {
    override val descriptor = buildClassSerialDescriptor("BackgroundReplacement")
    override fun serialize(encoder: Encoder, value: BackgroundReplacement) {
        val e = encoder as JsonEncoder
        e.encodeJsonElement(
            when (value) {
                BackgroundReplacement.Blur -> caseObject("blur")
                BackgroundReplacement.Transparent -> caseObject("transparent")
                is BackgroundReplacement.Color -> caseObject("color", e.json.encodeToJsonElement(RGBAColor.serializer(), value.color))
            }
        )
    }

    override fun deserialize(decoder: Decoder): BackgroundReplacement {
        val (json, obj) = decoder.json()
        obj["color"]?.let { return BackgroundReplacement.Color(json.decodeFromJsonElement(it.jsonObject.getValue("_0"))) }
        if (obj.containsKey("transparent")) return BackgroundReplacement.Transparent
        return BackgroundReplacement.Blur
    }
}

/** Removed caption styles open as the closest remaining one (IMPLEMENTATION §4.2 rule 4). */
object CaptionPresetSerializer : KSerializer<CaptionPreset> {
    override val descriptor = PrimitiveSerialDescriptor("CaptionPreset", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: CaptionPreset) = encoder.encodeString(value.raw)
    override fun deserialize(decoder: Decoder): CaptionPreset = when (val raw = decoder.decodeString()) {
        "minimal" -> CaptionPreset.CLASSIC
        "neon" -> CaptionPreset.KARAOKE
        else -> CaptionPreset.entries.firstOrNull { it.raw == raw } ?: CaptionPreset.KARAOKE
    }
}

/** Reads a JSON value as a plain string, for tests and debugging. */
fun JsonElement.text(): String = jsonPrimitive.content
