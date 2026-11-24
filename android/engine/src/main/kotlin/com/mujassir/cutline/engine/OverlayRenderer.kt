package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.LruCache
import com.mujassir.cutline.core.CaptionPreset
import com.mujassir.cutline.core.CaptionSegment
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.OverlayAnchor
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.RGBAColor
import com.mujassir.cutline.core.Size
import com.mujassir.cutline.core.TextAnimation
import com.mujassir.cutline.core.TextOverlay
import com.mujassir.cutline.core.TextStyle
import com.mujassir.cutline.core.Watermark
import com.mujassir.cutline.core.render.LayerGeometry
import java.io.File
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Draws everything above the clips for one frame (IMPLEMENTATION §8.1 steps 4–6): text overlays,
 * the watermark and captions, into a full-canvas bitmap. Used by the preview, the export and the
 * editor's text hit-testing.
 */
class OverlayRenderer(
    private val canvasW: Int,
    private val canvasH: Int,
    private val mediaFile: (String) -> File,
) {
    private val cache = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    /** Live centre for a text being dragged on the preview (drawn without rebuilding). */
    @Volatile var dragOverride: Pair<UUID, Pair<Double, Double>>? = null

    /** Draws the overlays at `time` into `target` (cleared first). Returns false when there's nothing to draw. */
    fun draw(project: Project, time: MediaTime, animate: Boolean, target: Bitmap): Boolean {
        val c = Canvas(target)
        c.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        var any = false
        for (t in project.textOverlays) if (time in t.range) { drawText(c, t, time, animate); any = true }
        project.watermark?.let { drawWatermark(c, it); any = true }
        if (project.captions.isVisible) {
            val seg = activeCaption(project.captions.segments, time)
            if (seg != null) { drawCaption(c, project, seg, time); any = true }
        }
        return any
    }

    /** Where a text is drawn (canvas-normalized centre and size in px), for hit-testing drags. */
    fun textFrame(t: TextOverlay): Pair<Pair<Double, Double>, Size>? {
        val bmp = textBitmap(t.text, t.style, null) ?: return null
        val size = Size(bmp.width.toDouble(), bmp.height.toDouble())
        return center(t, size) to size
    }

    private fun center(t: TextOverlay, size: Size): Pair<Double, Double> {
        dragOverride?.let { (id, c) -> if (id == t.id) return c }
        return t.anchor?.center(size, Size(canvasW.toDouble(), canvasH.toDouble())) ?: (t.centerX to t.centerY)
    }

    private fun textBitmap(text: String, style: TextStyle, visible: Int?): Bitmap? {
        val key = "t|$text|$style|$visible|$canvasW|$canvasH"
        cache.get(key)?.let { return it }
        val b = TextRenderer.render(text, style, canvasW, canvasH, visible) ?: return null
        cache.put(key, b)
        return b
    }

    private fun drawText(c: Canvas, t: TextOverlay, time: MediaTime, animate: Boolean) {
        val local = (time - t.range.start).seconds
        val dur = t.range.duration.seconds
        var opacity = 1.0; var scale = t.scale; var dx = 0.0; var dy = 0.0; var rotation = t.rotation
        var visible: Int? = null
        if (animate) {
            val anim = t.animation
            if (anim != null) {
                val a = LayerGeometry.clipAnimation(anim, local, dur)
                opacity *= a.opacity; scale *= a.scale; dx += a.offset.x; dy += a.offset.y; rotation += a.rotation
            } else {
                // Older text animations (§8.6.1).
                val d = min(0.4, dur / 3)
                if (d > 0 && local < d) {
                    val p = local / d
                    when (t.animationIn) {
                        TextAnimation.FADE -> opacity *= p
                        TextAnimation.POP -> { scale *= 1 + 2.70158 * (p - 1).pow(3) + 1.70158 * (p - 1).pow(2); opacity *= min(1.0, 2 * p) }
                        TextAnimation.SLIDE_UP -> { dy += (1 - LayerGeometry.smoothstep(p)) * 0.06; opacity *= p }
                        TextAnimation.TYPEWRITER -> visible = ceil(t.text.length * p).toInt()
                        TextAnimation.BOUNCE -> { dy -= abs(sin(2.5 * PI * p)) * (1 - p) * 0.04; opacity *= min(1.0, 3 * p) }
                        TextAnimation.NONE -> {}
                    }
                }
                if (d > 0 && local > dur - d) {
                    val p = (dur - local) / d
                    when (t.animationOut) {
                        TextAnimation.FADE, TextAnimation.TYPEWRITER -> opacity *= p
                        TextAnimation.POP -> { scale *= 1 + 2.70158 * (p - 1).pow(3) + 1.70158 * (p - 1).pow(2); opacity *= min(1.0, 2 * p) }
                        TextAnimation.SLIDE_UP -> { dy += (1 - LayerGeometry.smoothstep(p)) * 0.06; opacity *= p }
                        TextAnimation.BOUNCE -> { dy -= abs(sin(2.5 * PI * p)) * (1 - p) * 0.04; opacity *= min(1.0, 3 * p) }
                        TextAnimation.NONE -> {}
                    }
                }
            }
        }
        if (opacity <= 0.001) return
        val full = textBitmap(t.text, t.style, null) ?: return
        val bmp = if (visible != null) textBitmap(t.text, t.style, visible) ?: return else full
        val (cx, cy) = center(t, Size(full.width.toDouble(), full.height.toDouble()))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { alpha = (opacity.coerceIn(0.0, 1.0) * 255).toInt() }
        c.save()
        c.translate(((cx + dx) * canvasW).toFloat(), ((cy + dy) * canvasH).toFloat())
        c.rotate(Math.toDegrees(rotation).toFloat())
        c.scale(scale.toFloat(), scale.toFloat())
        c.drawBitmap(bmp, -full.width / 2f, -full.height / 2f, paint)
        c.restore()
    }

    private fun drawWatermark(c: Canvas, w: Watermark) {
        val bmp: Bitmap = when (w.kind) {
            Watermark.Kind.TEXT -> {
                if (w.text.isBlank()) return
                val style = TextStyle(fontName = "HelveticaNeue-Bold", size = 0.12 * w.size, color = w.color, shadow = true)
                textBitmap(w.text, style, null) ?: return
            }
            Watermark.Kind.IMAGE -> {
                val name = w.imageFileName ?: return
                val key = "wm|$name|${w.size}|$canvasW"
                cache.get(key) ?: run {
                    val src = Thumbnails.decodeImage(mediaFile(name), 1024) ?: return
                    val width = (canvasW * w.size).toInt().coerceAtLeast(1)
                    val height = (src.height * width / src.width.toDouble()).toInt().coerceAtLeast(1)
                    Bitmap.createScaledBitmap(src, width, height, true).also { cache.put(key, it) }
                }
            }
        }
        val (cx, cy) = w.anchor.center(Size(bmp.width.toDouble(), bmp.height.toDouble()), Size(canvasW.toDouble(), canvasH.toDouble()), 0.035)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG).apply { alpha = (w.opacity.coerceIn(0.0, 1.0) * 255).toInt() }
        c.drawBitmap(bmp, (cx * canvasW - bmp.width / 2).toFloat(), (cy * canvasH - bmp.height / 2).toFloat(), paint)
    }

    private fun drawCaption(c: Canvas, project: Project, seg: CaptionSegment, time: MediaTime) {
        val track = project.captions
        val activeIndex = seg.words.indexOfLast { it.range.start <= time }
        val (font, size, outline, shadow, box) = when (track.preset) {
            CaptionPreset.CLASSIC -> CaptionLook("HelveticaNeue-Medium", 0.036, 0.0, false, RGBAColor(0.0, 0.0, 0.0, 0.6))
            CaptionPreset.KARAOKE -> CaptionLook("HelveticaNeue-Bold", 0.042, 0.004 / 0.042, true, null)
            CaptionPreset.BOLD -> CaptionLook("Futura-CondensedExtraBold", 0.055, 0.006 / 0.055, true, null)
        }
        val upper = track.preset == CaptionPreset.BOLD
        val words = seg.words.map { if (upper) it.text.uppercase() else it.text }
        val text = words.joinToString(" ")
        val style = TextStyle(fontName = font, size = size, color = RGBAColor.WHITE,
            outlineColor = if (outline > 0) RGBAColor.BLACK else null, outlineWidth = outline, shadow = shadow, backgroundColor = box)
        val bmp: Bitmap = if (track.preset == CaptionPreset.CLASSIC || activeIndex < 0) {
            textBitmap(text, style, null) ?: return
        } else {
            // Highlight the active word: render with a coloured span over the word.
            val key = "c|$text|$activeIndex|${track.preset}|${track.highlightColor}|$canvasW"
            cache.get(key) ?: run {
                val start = words.take(activeIndex).sumOf { it.length + 1 }
                val spanned = SpannableString(text).apply {
                    setSpan(ForegroundColorSpan(track.highlightColor.argb()), start, start + words[activeIndex].length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                CaptionText.render(spanned, style, canvasW, canvasH, 0.86)?.also { cache.put(key, it) } ?: return
            }
        }
        var scale = 1.0
        if (track.preset != CaptionPreset.CLASSIC && activeIndex >= 0) {
            val since = (time - seg.words[activeIndex].range.start).seconds
            if (since < 0.12) scale = 1 + 0.04 * (1 - since / 0.12)
        }
        c.save()
        c.translate(canvasW / 2f, (track.positionY * canvasH).toFloat())
        c.scale(scale.toFloat(), scale.toFloat())
        c.drawBitmap(bmp, -bmp.width / 2f, -bmp.height / 2f, Paint(Paint.FILTER_BITMAP_FLAG))
        c.restore()
    }

    private data class CaptionLook(val font: String, val size: Double, val outline: Double, val shadow: Boolean, val box: RGBAColor?)

    companion object {
        /** The caption showing at `t` (§6.5): the first where start ≤ t < end + 0.25 s. */
        fun activeCaption(segments: List<CaptionSegment>, t: MediaTime): CaptionSegment? =
            segments.firstOrNull { it.words.isNotEmpty() && it.range.start <= t && t < it.range.end + MediaTime.seconds(0.25) }

        /** Overlays only animate with the anchor margin used for text. */
        @Suppress("unused") val TEXT_MARGIN = OverlayAnchor.CENTER
    }
}

/** Captions use the text renderer with a span for the active word and 0.86 W maximum width. */
object CaptionText {
    fun render(text: CharSequence, style: TextStyle, canvasW: Int, canvasH: Int, maxWidthFraction: Double): Bitmap? {
        // Render via the plain renderer at the narrower width, then redraw the span on top.
        val plain = TextRenderer.render(text.toString(), style, (canvasW * maxWidthFraction / 0.9).toInt(), canvasH) ?: return null
        val spanned = text as? Spanned ?: return plain
        val spans = spanned.getSpans(0, text.length, ForegroundColorSpan::class.java)
        if (spans.isEmpty()) return plain
        val c = Canvas(plain)
        val fontSize = (canvasH * style.size).toFloat()
        val paint = android.text.TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Fonts.typeface(style.fontName); textSize = fontSize }
        val maxWidth = (canvasW * maxWidthFraction).toInt()
        val layout = TextRenderer.layout(text.toString(), paint, maxWidth)
        val colored = TextRenderer.layout(text.toString(), paint, layout.width).let {
            android.text.StaticLayout.Builder.obtain(spanned, 0, spanned.length, paint, layout.width)
                .setAlignment(android.text.Layout.Alignment.ALIGN_CENTER).setIncludePad(false).build()
        }
        val outline = (fontSize * style.outlineWidth).toFloat()
        val pad = ceil(fontSize * 0.35 + outline * 2).toInt()
        val contentW = plain.width - pad * 2
        c.save(); c.translate(pad + (contentW - colored.width) / 2f, pad.toFloat())
        // Only the coloured word is redrawn: clip to its bounds.
        val span = spans[0]
        val s = spanned.getSpanStart(span); val e = spanned.getSpanEnd(span)
        val line = colored.getLineForOffset(s)
        val left = colored.getPrimaryHorizontal(s); val right = colored.getPrimaryHorizontal(e)
        c.clipRect(left - 2, colored.getLineTop(line).toFloat(), right + 2, colored.getLineBottom(line).toFloat())
        colored.draw(c)
        c.restore()
        return plain
    }
}
