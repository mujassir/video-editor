@file:UseSerializers(UUIDSerializer::class)

package com.mujassir.cutline.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import java.util.UUID

// The project model. Every type mirrors the iOS reference (EditorKit/Model/Project.swift) and
// encodes to the shared project file format (IMPLEMENTATION §3–4, docs/spec/project.sample.json).
// All types are immutable: edits return new values, so undo snapshots never share state.

// MARK: - Media

@Serializable
enum class MediaKind { @SerialName("video") VIDEO, @SerialName("photo") PHOTO, @SerialName("audio") AUDIO }

/** How strongly background noise is removed (DNS). */
@Serializable
enum class NoiseReduction(val title: String) {
    @SerialName("low") LOW("Low"), @SerialName("medium") MEDIUM("Medium"), @SerialName("high") HIGH("High");
    val raw: String get() = name.lowercase()
}

/** Width × height. Encoded as a two-number array `[w, h]`. */
@Serializable(with = SizeSerializer::class)
data class Size(val width: Double, val height: Double) {
    companion object { val ZERO = Size(0.0, 0.0) }
}

/** A source file copied into the project's Media folder. */
@Serializable
data class MediaItem(
    val id: UUID = UUID.randomUUID(),
    val kind: MediaKind,
    /** File name relative to the project's Media directory. */
    val fileName: String,
    /** Upright size (width and height swapped for odd quarter turns). */
    val naturalSize: Size,
    val duration: MediaTime,
    val hasAudio: Boolean,
    val frameRate: Double = 30.0,
    val displayName: String = "",
    val reversedFileName: String? = null,
    val denoisedFileNames: Map<NoiseReduction, String>? = null,
    /** Clockwise quarter turns that make the raw frames upright. */
    val sourceQuarterTurns: Int = 0,
)

// MARK: - Canvas

@Serializable
enum class AspectRatio(val raw: String, val value: Double) {
    @SerialName("9:16") PORTRAIT_9X16("9:16", 9.0 / 16.0),
    @SerialName("3:4") PORTRAIT_3X4("3:4", 3.0 / 4.0),
    @SerialName("1:1") SQUARE("1:1", 1.0),
    @SerialName("4:5") PORTRAIT_4X5("4:5", 4.0 / 5.0),
    @SerialName("16:9") LANDSCAPE_16X9("16:9", 16.0 / 9.0);

    /** Render size whose short edge is `shortEdge` (even numbers, for encoders). */
    fun renderSize(shortEdge: Int): Size {
        fun even(v: Double) = (roundHalfAway(v / 2) * 2)
        return if (value >= 1) Size(even(shortEdge * value), shortEdge.toDouble())
        else Size(shortEdge.toDouble(), even(shortEdge / value))
    }
}

@Serializable
data class RGBAColor(val r: Double, val g: Double, val b: Double, val a: Double = 1.0) {
    companion object {
        val BLACK = RGBAColor(0.0, 0.0, 0.0)
        val WHITE = RGBAColor(1.0, 1.0, 1.0)
        val YELLOW = RGBAColor(1.0, 0.86, 0.1)
    }
}

/** Behind fitted media: a blurred copy of the frame, or a solid colour (CNV-3). */
@Serializable(with = CanvasBackgroundSerializer::class)
sealed interface CanvasBackground {
    data object Blur : CanvasBackground
    data class Color(val color: RGBAColor) : CanvasBackground
}

@Serializable
enum class ContentFit(val displayName: String) {
    @SerialName("fit") FIT("Fit"), @SerialName("fill") FILL("Fill"), @SerialName("stretch") STRETCH("Stretch")
}

@Serializable
enum class ContentAnchor(val displayName: String) {
    @SerialName("center") CENTER("Center"), @SerialName("top") TOP("Top"), @SerialName("bottom") BOTTOM("Bottom"),
    @SerialName("left") LEFT("Left"), @SerialName("right") RIGHT("Right")
}

// MARK: - Clip settings

/** Normalized crop rectangle in source space (0…1). */
@Serializable
data class CropRect(val x: Double = 0.0, val y: Double = 0.0, val width: Double = 1.0, val height: Double = 1.0) {
    val isFull get() = x == 0.0 && y == 0.0 && width == 1.0 && height == 1.0
    companion object { val FULL = CropRect() }
}

@Serializable
data class ClipTransform(
    val crop: CropRect = CropRect.FULL,
    /** Clockwise rotation in quarter turns (0…3). */
    val quarterTurns: Int = 0,
    val flipHorizontal: Boolean = false,
    val flipVertical: Boolean = false,
    val scale: Double = 1.0,
    val offsetX: Double = 0.0,
    val offsetY: Double = 0.0,
    val fit: ContentFit = ContentFit.FIT,
    val anchor: ContentAnchor? = null,
)

/** Colour adjustments, neutral at 0 (ADJ). */
@Serializable
data class ColorAdjustments(
    val exposure: Double = 0.0,
    val contrast: Double = 0.0,
    val saturation: Double = 0.0,
    val warmth: Double = 0.0,
    val highlights: Double = 0.0,
    val shadows: Double = 0.0,
    val vignette: Double = 0.0,
    val sharpen: Double = 0.0,
) {
    val isNeutral get() = this == ColorAdjustments()
}

@Serializable
data class FilterSetting(val filterID: String, val intensity: Double = 1.0)

@Serializable
enum class TransitionKind(val displayName: String) {
    @SerialName("fade") FADE("Fade"), @SerialName("dissolve") DISSOLVE("Dissolve"),
    @SerialName("slideLeft") SLIDE_LEFT("Slide"), @SerialName("slideUp") SLIDE_UP("Push Up"),
    @SerialName("zoom") ZOOM("Zoom"), @SerialName("wipe") WIPE("Wipe"), @SerialName("blur") BLUR("Blur"),
    @SerialName("glitch") GLITCH("Glitch")
}

@Serializable
data class Transition(val kind: TransitionKind, val duration: MediaTime = MediaTime.seconds(0.5))

/** Entrance / exit animation (exits play the entrance in reverse). ANM-2. */
@Serializable
enum class ClipEntrance(val displayName: String) {
    @SerialName("fade") FADE("Fade"), @SerialName("zoomIn") ZOOM_IN("Zoom In"), @SerialName("zoomOut") ZOOM_OUT("Zoom Out"),
    @SerialName("slideLeft") SLIDE_LEFT("Slide ←"), @SerialName("slideRight") SLIDE_RIGHT("Slide →"),
    @SerialName("slideUp") SLIDE_UP("Slide ↑"), @SerialName("slideDown") SLIDE_DOWN("Slide ↓"),
    @SerialName("rotate") ROTATE("Rotate"), @SerialName("spin") SPIN("Spin"), @SerialName("pop") POP("Pop"),
    @SerialName("bounce") BOUNCE("Bounce"), @SerialName("drop") DROP("Drop"), @SerialName("blur") BLUR("Blur"),
    @SerialName("swing") SWING("Swing")
}

/** Looping emphasis for the whole clip. ANM-3. */
@Serializable
enum class ClipCombo(val displayName: String) {
    @SerialName("pulse") PULSE("Pulse"), @SerialName("heartbeat") HEARTBEAT("Heartbeat"), @SerialName("shake") SHAKE("Shake"),
    @SerialName("wobble") WOBBLE("Wobble"), @SerialName("swing") SWING("Swing"), @SerialName("float") FLOAT("Float"),
    @SerialName("rock") ROCK("Rock"), @SerialName("spin") SPIN("Spin")
}

@Serializable
data class ClipAnimation(
    val entrance: ClipEntrance? = null,
    val exit: ClipEntrance? = null,
    val combo: ClipCombo? = null,
    val inDuration: Double = 0.6,
    val outDuration: Double = 0.6,
) {
    val isEmpty get() = entrance == null && exit == null && combo == null
}

/** Camera move over a still. ANM-4. */
@Serializable
enum class PhotoMotion(val displayName: String) {
    @SerialName("none") NONE("None"), @SerialName("zoomIn") ZOOM_IN("Zoom In"), @SerialName("zoomOut") ZOOM_OUT("Zoom Out"),
    @SerialName("panLeft") PAN_LEFT("Pan Left"), @SerialName("panRight") PAN_RIGHT("Pan Right"),
    @SerialName("panUp") PAN_UP("Pan Up"), @SerialName("panDown") PAN_DOWN("Pan Down"),
    @SerialName("kenBurns") KEN_BURNS("Ken Burns")
}

/** Cutout (CUT): what replaces the background behind a person. */
@Serializable(with = BackgroundReplacementSerializer::class)
sealed interface BackgroundReplacement {
    data object Blur : BackgroundReplacement
    data class Color(val color: RGBAColor) : BackgroundReplacement
    data object Transparent : BackgroundReplacement
}

@Serializable
data class ReframeKeyframe(val time: MediaTime, val centerX: Double, val centerY: Double)

// MARK: - Clips

/** A clip on the main (magnetic) track. */
@Serializable
data class VideoClip(
    val id: UUID = UUID.randomUUID(),
    val mediaID: UUID,
    val kind: MediaKind,
    /** Portion of the source used, in source time. */
    val sourceRange: MediaTimeRange,
    val speed: Double = 1.0,
    val isReversed: Boolean = false,
    val freezeAt: MediaTime? = null,
    val volume: Double = 1.0,
    val isMuted: Boolean = false,
    /** Older per-clip Denoise; plays only while `Project.noiseReduction` is nil. */
    val noiseReduction: NoiseReduction? = null,
    val transform: ClipTransform = ClipTransform(),
    val filter: FilterSetting? = null,
    val adjustments: ColorAdjustments = ColorAdjustments(),
    val backgroundRemoval: BackgroundReplacement? = null,
    val reframe: List<ReframeKeyframe> = emptyList(),
    /** Transition from this clip into the next. */
    val transitionOut: Transition? = null,
    val photoMotion: PhotoMotion? = null,
    val animation: ClipAnimation? = null,
    /** Set when this clip is an opening / closing slide. */
    val titleCard: TitleCard? = null,
) {
    /** Length on the timeline. */
    val timelineDuration: MediaTime
        get() = if (kind == MediaKind.PHOTO || freezeAt != null) sourceRange.duration else sourceRange.duration.dividedBy(speed)

    val isStill get() = kind == MediaKind.PHOTO || freezeAt != null
    val hasAudio get() = !isStill

    /** Clip time (0 until timelineDuration) → source time. */
    fun sourceTime(atClipTime: MediaTime): MediaTime {
        freezeAt?.let { return it }
        if (kind == MediaKind.PHOTO) return MediaTime.ZERO
        val offset = atClipTime.multipliedBy(speed)
        return if (isReversed) sourceRange.end - offset else sourceRange.start + offset
    }
}

/** Free-positioned audio on a lane. */
@Serializable
data class AudioClip(
    val id: UUID = UUID.randomUUID(),
    val mediaID: UUID,
    val role: Role,
    val sourceRange: MediaTimeRange,
    /** Position on the timeline. */
    val start: MediaTime,
    val volume: Double = 1.0,
    val fadeIn: MediaTime = MediaTime.ZERO,
    val fadeOut: MediaTime = MediaTime.ZERO,
    val lane: Int = 0,
    val autoDuck: Boolean = false,
    val duckLevel: Double? = null,
    val beats: List<MediaTime> = emptyList(),
    val name: String = "",
    /** nil (older projects) means yes for music, no for other roles. */
    val fitsVideo: Boolean? = null,
    /** Marker sections (source time), engine only. nil = one section at full volume. */
    val sections: List<AudioSection>? = null,
) {
    @Serializable
    enum class Role {
        @SerialName("music") MUSIC, @SerialName("voiceover") VOICEOVER,
        @SerialName("effect") EFFECT, @SerialName("extracted") EXTRACTED
    }

    val resolvedDuckLevel get() = (duckLevel ?: 0.25).coerceIn(0.0, 1.0)
    val followsVideo get() = fitsVideo ?: (role == Role.MUSIC)

    /** Sections clipped to the trimmed range (always at least one). */
    val resolvedSections: List<AudioSection>
        get() {
            val whole = listOf(AudioSection(sourceRange.start, sourceRange.end))
            if (sections.isNullOrEmpty()) return whole
            val clipped = sections.mapNotNull { s ->
                val a = MediaTime.max(s.start, sourceRange.start)
                val b = MediaTime.min(s.end, sourceRange.end)
                if (b > a) s.copy(start = a, end = b) else null
            }
            return clipped.ifEmpty { whole }
        }

    /** How long the clip plays (deleted sections cut out). */
    val playedDuration: MediaTime
        get() = resolvedSections.filter { !it.deleted }.fold(MediaTime.ZERO) { acc, s -> acc + (s.end - s.start) }

    val hasSectionEdits: Boolean
        get() {
            val s = sections ?: return false
            return s.size > 1 || s.any { it.deleted || it.volume != 1.0 }
        }

    val timelineRange get() = MediaTimeRange(start, playedDuration)

    val timelineBeats get() = beats.filter { it in sourceRange }.map { start + (it - sourceRange.start) }
}

@Serializable
data class AudioSection(
    val start: MediaTime,
    val end: MediaTime,
    val volume: Double = 1.0,
    val deleted: Boolean = false,
) {
    val duration get() = end - start
}

/** Older text animations (§8.6.1). */
@Serializable
enum class TextAnimation(val displayName: String) {
    @SerialName("none") NONE("None"), @SerialName("fade") FADE("Fade"), @SerialName("pop") POP("Pop"),
    @SerialName("slideUp") SLIDE_UP("Rise"), @SerialName("typewriter") TYPEWRITER("Type"), @SerialName("bounce") BOUNCE("Bounce")
}

@Serializable
data class TextStyle(
    val fontName: String = "HelveticaNeue-Bold",
    /** Font size as a fraction of canvas height. */
    val size: Double = 0.06,
    val color: RGBAColor = RGBAColor.WHITE,
    val outlineColor: RGBAColor? = null,
    val outlineWidth: Double = 0.0,
    val shadow: Boolean = true,
    val backgroundColor: RGBAColor? = null,
)

@Serializable
data class TextOverlay(
    val id: UUID = UUID.randomUUID(),
    val text: String,
    val range: MediaTimeRange,
    val style: TextStyle = TextStyle(),
    /** Centre in canvas-normalized coordinates (0…1, origin top-left). */
    val centerX: Double = 0.5,
    val centerY: Double = 0.5,
    val rotation: Double = 0.0,
    val scale: Double = 1.0,
    val animationIn: TextAnimation = TextAnimation.POP,
    val animationOut: TextAnimation = TextAnimation.FADE,
    val animation: ClipAnimation? = null,
    /** Fixed spot; nil = free position. */
    val anchor: OverlayAnchor? = null,
)

/** Fixed spots on the canvas for text and watermarks. */
@Serializable
enum class OverlayAnchor(val displayName: String, val ax: Int, val ay: Int) {
    @SerialName("topLeft") TOP_LEFT("Top Left", -1, -1), @SerialName("top") TOP("Top", 0, -1),
    @SerialName("topRight") TOP_RIGHT("Top Right", 1, -1), @SerialName("left") LEFT("Left", -1, 0),
    @SerialName("center") CENTER("Center", 0, 0), @SerialName("right") RIGHT("Right", 1, 0),
    @SerialName("bottomLeft") BOTTOM_LEFT("Bottom Left", -1, 1), @SerialName("bottom") BOTTOM("Bottom", 0, 1),
    @SerialName("bottomRight") BOTTOM_RIGHT("Bottom Right", 1, 1);

    /** Centre (canvas-normalized) for an item of `size` px kept `margin` from the edges (§8.6). */
    fun center(size: Size, canvas: Size, margin: Double = 0.04): Pair<Double, Double> {
        val hw = size.width / canvas.width / 2
        val hh = size.height / canvas.height / 2
        val mx = margin
        val my = margin * canvas.width / canvas.height.coerceAtLeast(1.0)
        val x = if (ax < 0) mx + hw else if (ax > 0) 1 - mx - hw else 0.5
        val y = if (ay < 0) my + hh else if (ay > 0) 1 - my - hh else 0.5
        return x to y
    }
}

/** Logo or text over the whole video (WMK). */
@Serializable
data class Watermark(
    val kind: Kind = Kind.TEXT,
    val text: String = "@yourname",
    val imageFileName: String? = null,
    val anchor: OverlayAnchor = OverlayAnchor.BOTTOM_RIGHT,
    val opacity: Double = 0.7,
    val size: Double = 0.22,
    val color: RGBAColor = RGBAColor.WHITE,
) {
    @Serializable
    enum class Kind { @SerialName("text") TEXT, @SerialName("image") IMAGE }
}

/** Opening / closing slide content (TTL). The slide is a photo clip rendered from this. */
@Serializable
data class TitleCard(
    val placement: Placement,
    val title: String,
    val subtitle: String = "",
    val background: RGBAColor = RGBAColor(0.08, 0.08, 0.1),
    val accent: RGBAColor = RGBAColor(1.0, 0.24, 0.38),
    val textColor: RGBAColor = RGBAColor.WHITE,
    val gradient: Boolean = true,
) {
    @Serializable
    enum class Placement { @SerialName("opening") OPENING, @SerialName("closing") CLOSING }

    data class Preset(
        val id: String, val name: String, val background: RGBAColor, val accent: RGBAColor,
        val textColor: RGBAColor, val gradient: Boolean,
    )

    fun applying(p: Preset) = copy(background = p.background, accent = p.accent, textColor = p.textColor, gradient = p.gradient)

    /** The preset these colours match, if any. */
    val preset: Preset? get() = PRESETS.firstOrNull { it.background == background && it.accent == accent && it.textColor == textColor }

    companion object {
        val PRESETS = listOf(
            Preset("midnight", "Midnight", RGBAColor(0.08, 0.08, 0.1), RGBAColor(1.0, 0.24, 0.38), RGBAColor.WHITE, true),
            Preset("sunset", "Sunset", RGBAColor(0.55, 0.12, 0.22), RGBAColor(1.0, 0.6, 0.2), RGBAColor.WHITE, true),
            Preset("ocean", "Ocean", RGBAColor(0.04, 0.12, 0.28), RGBAColor(0.2, 0.85, 0.85), RGBAColor.WHITE, true),
            Preset("forest", "Forest", RGBAColor(0.06, 0.2, 0.12), RGBAColor(0.6, 0.9, 0.4), RGBAColor.WHITE, true),
            Preset("grape", "Grape", RGBAColor(0.2, 0.08, 0.35), RGBAColor(0.85, 0.5, 1.0), RGBAColor.WHITE, true),
            Preset("paper", "Paper", RGBAColor(0.96, 0.95, 0.92), RGBAColor(1.0, 0.24, 0.38), RGBAColor(0.1, 0.1, 0.12), false),
            Preset("noir", "Noir", RGBAColor.BLACK, RGBAColor.WHITE, RGBAColor.WHITE, false),
        )
    }
}

// MARK: - Captions

@Serializable
data class CaptionWord(val text: String, val range: MediaTimeRange)

@Serializable
data class CaptionSegment(val id: UUID = UUID.randomUUID(), val words: List<CaptionWord>) {
    val text get() = words.joinToString(" ") { it.text }
    val range: MediaTimeRange
        get() {
            val first = words.firstOrNull() ?: return MediaTimeRange.EMPTY
            return MediaTimeRange.of(first.range.start, words.last().range.end)
        }
}

/** Caption styles (CAP-8). Reading maps the removed `minimal` → classic and `neon` → karaoke. */
@Serializable(with = CaptionPresetSerializer::class)
enum class CaptionPreset(val raw: String, val displayName: String) {
    CLASSIC("classic", "Classic"), KARAOKE("karaoke", "Karaoke"), BOLD("bold", "Bold")
}

@Serializable
data class CaptionTrack(
    val segments: List<CaptionSegment> = emptyList(),
    val preset: CaptionPreset = CaptionPreset.KARAOKE,
    val highlightColor: RGBAColor = RGBAColor.YELLOW,
    /** Vertical centre (0 top … 1 bottom). */
    val positionY: Double = 0.78,
    val isVisible: Boolean = true,
) {
    companion object {
        val FILLER_WORDS = setOf("um", "umm", "ummm", "uh", "uhh", "uhhh", "ah", "ahh", "ahhh",
            "er", "err", "erm", "hmm", "hm", "mm", "mmm")

        fun isFiller(word: String): Boolean =
            word.lowercase().trim { it.isWhitespace() || !it.isLetterOrDigit() } in FILLER_WORDS
    }

    /** Removes filler words; captions left empty are dropped (CAP-9). Returns (track, removed). */
    fun removingFillers(): Pair<CaptionTrack, Int> {
        var removed = 0
        val out = segments.map { seg ->
            val words = seg.words
            val kept = words.filter { !isFiller(it.text) }.toMutableList()
            removed += words.size - kept.size
            if (kept.size == words.size || kept.isEmpty()) {
                return@map if (kept.isEmpty()) seg.copy(words = emptyList()) else seg
            }
            // "Um, so we…" → "So we…": keep the sentence capitalised.
            val firstChar = kept[0].text.firstOrNull()
            if (isFiller(words[0].text) && firstChar != null && firstChar.isLowerCase() &&
                words[0].text.firstOrNull()?.isUpperCase() == true
            ) {
                kept[0] = kept[0].copy(text = firstChar.uppercase() + kept[0].text.drop(1))
            }
            // "…watching, um" → "…watching": no dangling comma.
            if (isFiller(words.last().text) && kept.last().text.endsWith(",")) {
                kept[kept.size - 1] = kept.last().copy(text = kept.last().text.dropLast(1))
            }
            seg.copy(words = kept)
        }.filter { it.words.isNotEmpty() }
        return copy(segments = out) to removed
    }
}

// MARK: - Project

@Serializable
data class Project(
    val version: Int = CURRENT_VERSION,
    val id: UUID = UUID.randomUUID(),
    val name: String,
    /** Seconds since 2001-01-01 UTC (the Apple reference date), IMPLEMENTATION §4.2. */
    val createdAt: Double = AppleDate.now(),
    val modifiedAt: Double = createdAt,
    val aspectRatio: AspectRatio = AspectRatio.PORTRAIT_9X16,
    val background: CanvasBackground = CanvasBackground.Blur,
    val frameRate: Int = 30,
    val media: List<MediaItem> = emptyList(),
    val clips: List<VideoClip> = emptyList(),
    val audioClips: List<AudioClip> = emptyList(),
    val textOverlays: List<TextOverlay> = emptyList(),
    val captions: CaptionTrack = CaptionTrack(),
    val watermark: Watermark? = null,
    val defaultFit: ContentFit? = null,
    val defaultAnchor: ContentAnchor? = null,
    /** Denoise for the whole video (DNS-1). nil = off, or each clip's older value. */
    val noiseReduction: NoiseReduction? = null,
) {
    companion object { const val CURRENT_VERSION = 1 }

    fun mediaItem(id: UUID): MediaItem? = media.firstOrNull { it.id == id }
    fun clipIndex(id: UUID): Int? = clips.indexOfFirst { it.id == id }.takeIf { it >= 0 }
    fun clip(id: UUID): VideoClip? = clips.firstOrNull { it.id == id }
    fun audio(id: UUID): AudioClip? = audioClips.firstOrNull { it.id == id }
    fun text(id: UUID): TextOverlay? = textOverlays.firstOrNull { it.id == id }

    /** The level that plays for a clip's own sound (DNS-8). */
    fun noiseReduction(clip: VideoClip): NoiseReduction? = noiseReduction ?: clip.noiseReduction

    /** Media whose sound Denoise cleans: main-track video clips with sound, each once, in order. */
    val denoiseSources: List<MediaItem>
        get() {
            val seen = HashSet<UUID>()
            return clips.mapNotNull { clip ->
                if (clip.kind != MediaKind.VIDEO || clip.isStill || !seen.add(clip.mediaID)) return@mapNotNull null
                mediaItem(clip.mediaID)?.takeIf { it.hasAudio }
            }
        }
}

/** Dates in project.json: seconds since 2001-01-01 00:00:00 UTC. */
object AppleDate {
    /** Seconds between 1970-01-01 and 2001-01-01. */
    const val OFFSET = 978_307_200.0
    fun now(): Double = System.currentTimeMillis() / 1000.0 - OFFSET
    fun toEpochMillis(apple: Double): Long = ((apple + OFFSET) * 1000).toLong()
    fun fromEpochMillis(ms: Long): Double = ms / 1000.0 - OFFSET
}
