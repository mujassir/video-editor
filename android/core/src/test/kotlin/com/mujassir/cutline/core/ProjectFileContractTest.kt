package com.mujassir.cutline.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * IMPLEMENTATION §15.1: the shared project file must read, round-trip and match the expected values
 * on every platform. Mirrors ProjectFileContractTests on iOS.
 */
class ProjectFileContractTest {
    private val sampleFile = File(System.getProperty("cutline.repoRoot") ?: "../..", "docs/spec/project.sample.json")

    private fun u(s: String) = UUID.fromString(s)
    private fun s(v: Double) = MediaTime.seconds(v)

    /** The same project as iOS `ProjectFileContractTests.sample()`. */
    private fun sample(): Project {
        val video = MediaItem(u("22222222-2222-2222-2222-222222222222"), MediaKind.VIDEO, "A1B2.mov", Size(1080.0, 1920.0),
            s(8.0), true, 30.0, "Beach", reversedFileName = "rev-A1B2.mov",
            denoisedFileNames = mapOf(NoiseReduction.MEDIUM to "nr2-medium-A1B2.m4a"), sourceQuarterTurns = 1)
        val photo = MediaItem(u("33333333-3333-3333-3333-333333333333"), MediaKind.PHOTO, "C3D4.heic", Size(4032.0, 3024.0),
            MediaTime.ZERO, false, displayName = "Sunset")
        val song = MediaItem(u("44444444-4444-4444-4444-444444444444"), MediaKind.AUDIO, "music-sunrise-10.m4a", Size.ZERO,
            s(60.0), true, displayName = "Sunrise Drive")
        val v = VideoClip(
            id = u("55555555-5555-5555-5555-555555555555"), mediaID = video.id, kind = MediaKind.VIDEO,
            sourceRange = MediaTimeRange(s(1.0), s(4.0)), speed = 1.5, noiseReduction = NoiseReduction.MEDIUM,
            transform = ClipTransform(crop = CropRect(0.0, 0.1, 1.0, 0.8), fit = ContentFit.FILL, anchor = ContentAnchor.CENTER),
            filter = FilterSetting("teal_orange", 0.8), adjustments = ColorAdjustments(exposure = 0.2, vignette = 0.3),
            backgroundRemoval = BackgroundReplacement.Color(RGBAColor.BLACK),
            reframe = listOf(ReframeKeyframe(s(1.0), 0.5, 0.4)),
            transitionOut = Transition(TransitionKind.DISSOLVE, s(0.5)),
            animation = ClipAnimation(entrance = ClipEntrance.ZOOM_IN, combo = ClipCombo.PULSE),
        )
        val ph = VideoClip(id = u("66666666-6666-6666-6666-666666666666"), mediaID = photo.id, kind = MediaKind.PHOTO,
            sourceRange = MediaTimeRange(MediaTime.ZERO, s(3.0)), photoMotion = PhotoMotion.KEN_BURNS)
        val music = AudioClip(id = u("77777777-7777-7777-7777-777777777777"), mediaID = song.id, role = AudioClip.Role.MUSIC,
            sourceRange = MediaTimeRange(MediaTime.ZERO, s(60.0)), start = MediaTime.ZERO, volume = 0.7, fadeOut = s(1.5),
            autoDuck = true, duckLevel = 0.25, name = "Sunrise Drive", fitsVideo = true)
        val text = TextOverlay(id = u("88888888-8888-8888-8888-888888888888"), text = "Hello",
            range = MediaTimeRange(MediaTime.ZERO, s(3.0)),
            style = TextStyle(outlineColor = RGBAColor.BLACK, outlineWidth = 0.08), anchor = OverlayAnchor.TOP,
            animation = ClipAnimation(ClipEntrance.POP, ClipEntrance.FADE, null, 0.4, 0.4),
            animationIn = TextAnimation.NONE, animationOut = TextAnimation.NONE)
        val captions = CaptionTrack(segments = listOf(CaptionSegment(u("99999999-9999-9999-9999-999999999999"), listOf(
            CaptionWord("Hello", MediaTimeRange(s(0.5), s(0.4))), CaptionWord("there", MediaTimeRange(s(0.9), s(0.4))),
        ))))
        return Project(
            id = u("11111111-1111-1111-1111-111111111111"), name = "Sample", createdAt = 800_000_000.0, modifiedAt = 800_000_000.0,
            defaultFit = ContentFit.FILL, defaultAnchor = ContentAnchor.CENTER, noiseReduction = NoiseReduction.MEDIUM,
            media = listOf(video, photo, song), clips = listOf(v, ph), audioClips = listOf(music), textOverlays = listOf(text),
            captions = captions, watermark = Watermark(text = "@cutline"),
        )
    }

    @Test
    fun `PRJ-3 reads the shared sample file with every expected value`() {
        val decoded = decodeProject(sampleFile.readText())
        assertEquals(sample(), decoded)
        // A few spot checks that the encoding rules hold.
        assertEquals(Size(1080.0, 1920.0), decoded.media[0].naturalSize)
        assertEquals(240_000L, decoded.clips[0].sourceRange.duration.ticks)
        assertEquals(CanvasBackground.Blur, decoded.background)
        assertEquals(BackgroundReplacement.Color(RGBAColor.BLACK), decoded.clips[0].backgroundRemoval)
        assertEquals(800_000_000.0, decoded.createdAt, 0.0)
    }

    @Test
    fun `PRJ-3 writes the same JSON as iOS (every key, same values)`() {
        val ours = Json.parseToJsonElement(sample().encode())
        val theirs = Json.parseToJsonElement(sampleFile.readText())
        assertSameJson("", theirs, ours)
    }

    @Test
    fun `PRJ-3 round-trips and ignores unknown keys`() {
        val p = sample()
        assertEquals(p, decodeProject(p.encode()))
        val withExtra = sampleFile.readText().replaceFirst("{", "{\"futureField\": {\"x\": 1},")
        assertEquals(p, decodeProject(withExtra))
    }

    @Test
    fun `removed caption styles open as the closest remaining one`() {
        val minimal = sampleFile.readText().replace("\"karaoke\"", "\"minimal\"")
        assertEquals(CaptionPreset.CLASSIC, decodeProject(minimal).captions.preset)
        val neon = sampleFile.readText().replace("\"karaoke\"", "\"neon\"")
        assertEquals(CaptionPreset.KARAOKE, decodeProject(neon).captions.preset)
    }

    @Test
    fun `colour backgrounds use the associated-value shape`() {
        val p = sample().copy(background = CanvasBackground.Color(RGBAColor(0.1, 0.2, 0.3)))
        val text = p.encode()
        assertTrue(text, text.contains("\"background\":{\"color\":{\"_0\":{\"r\":0.1,\"g\":0.2,\"b\":0.3,\"a\":1.0}}}"))
        assertEquals(p, decodeProject(text))
    }

    /** Same keys and values; numbers compare numerically (iOS writes 1, Kotlin 1.0). */
    private fun assertSameJson(path: String, expected: JsonElement, actual: JsonElement) {
        when (expected) {
            is JsonObject -> {
                actual as JsonObject
                assertEquals("keys at $path", expected.keys, actual.keys)
                for (k in expected.keys) assertSameJson("$path.$k", expected.getValue(k), actual.getValue(k))
            }
            is JsonArray -> {
                actual as JsonArray
                assertEquals("length at $path", expected.size, actual.size)
                expected.indices.forEach { assertSameJson("$path[$it]", expected[it], actual[it]) }
            }
            is JsonPrimitive -> {
                actual as JsonPrimitive
                val e = expected.doubleOrNull; val a = actual.doubleOrNull
                when {
                    expected.isString -> assertEquals(path, expected.content, actual.content)
                    expected.booleanOrNull != null -> assertEquals(path, expected.booleanOrNull, actual.booleanOrNull)
                    e != null -> assertEquals(path, e, a!!, 1e-9)
                    else -> assertEquals(path, expected, actual)
                }
            }
        }
    }
}
