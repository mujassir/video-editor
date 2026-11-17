package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import com.mujassir.cutline.core.RGBAColor
import com.mujassir.cutline.core.TextStyle
import com.mujassir.cutline.core.TitleCard
import java.io.File
import java.io.FileOutputStream
import kotlin.math.ceil
import kotlin.math.max

/** The 8 text fonts (TXT-2): UI name ↔ the iOS PostScript name stored in projects. */
enum class TextFont(val title: String, val postScript: String) {
    BOLD("Bold", "HelveticaNeue-Bold"),
    CLASSIC("Classic", "Georgia-Bold"),
    ROUNDED("Rounded", "ArialRoundedMTBold"),
    CONDENSED("Condensed", "Futura-CondensedExtraBold"),
    ELEGANT("Elegant", "Didot-Bold"),
    MONO("Mono", "Menlo-Bold"),
    SCRIPT("Script", "SnellRoundhand-Black"),
    HEAVY("Heavy", "AvenirNext-Heavy");

    companion object {
        fun of(postScript: String) = entries.firstOrNull { it.postScript == postScript } ?: BOLD
    }
}

/**
 * Typefaces for the iOS font names (IMPLEMENTATION §8.6). Uses the platform's built-in families; the
 * same mapping must be used everywhere on Android. Parity note: bundled open fonts are the next step.
 */
object Fonts {
    fun typeface(postScript: String): Typeface = when (postScript) {
        "Georgia-Bold" -> Typeface.create(Typeface.SERIF, Typeface.BOLD)
        "ArialRoundedMTBold" -> Typeface.create("sans-serif-medium", Typeface.BOLD)
        "Futura-CondensedExtraBold" -> Typeface.create("sans-serif-condensed", Typeface.BOLD)
        "Didot-Bold" -> Typeface.create(Typeface.SERIF, Typeface.BOLD_ITALIC)
        "Menlo-Bold" -> Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        "SnellRoundhand-Black" -> Typeface.create("cursive", Typeface.BOLD)
        "AvenirNext-Heavy" -> Typeface.create("sans-serif-black", Typeface.NORMAL)
        "HelveticaNeue-Medium" -> Typeface.create("sans-serif-medium", Typeface.NORMAL)
        else -> Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
    }
}

fun RGBAColor.argb(): Int = Color.argb(
    (a * 255 + 0.5).toInt().coerceIn(0, 255), (r * 255 + 0.5).toInt().coerceIn(0, 255),
    (g * 255 + 0.5).toInt().coerceIn(0, 255), (b * 255 + 0.5).toInt().coerceIn(0, 255),
)

/** Draws one text overlay into its own bitmap (IMPLEMENTATION §8.6). */
object TextRenderer {
    /**
     * @param canvasW,canvasH output canvas in px; font size = canvasH × style.size.
     * @param visibleChars typewriter: characters shown (null = all).
     */
    fun render(text: String, style: TextStyle, canvasW: Int, canvasH: Int, visibleChars: Int? = null): Bitmap? {
        val shown = if (visibleChars != null) text.take(visibleChars) else text
        if (shown.isBlank()) return null
        val fontSize = (canvasH * style.size).toFloat()
        val outline = (fontSize * style.outlineWidth).toFloat()
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Fonts.typeface(style.fontName)
            textSize = fontSize
            color = style.color.argb()
        }
        val maxWidth = (0.9 * canvasW).toInt().coerceAtLeast(1)
        // Measure with the full text so the box doesn't jump while the typewriter reveals it.
        val full = layout(text, paint, maxWidth)
        val layout = if (shown == text) full else layout(shown, paint, full.width)
        val pad = ceil(fontSize * 0.35 + outline * 2).toInt()
        val contentW = (0 until full.lineCount).maxOf { ceil(full.getLineWidth(it).toDouble()).toInt() }.coerceAtLeast(1)
        val w = contentW + pad * 2
        val h = full.height + pad * 2
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        style.backgroundColor?.let { bg ->
            val rect = RectF(pad - 0.3f * fontSize, pad - 0.12f * fontSize, pad + contentW + 0.3f * fontSize, pad + full.height + 0.12f * fontSize)
            c.drawRoundRect(rect, 0.25f * fontSize, 0.25f * fontSize, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = bg.argb() })
        }
        c.save()
        c.translate(pad + (contentW - layout.width) / 2f, pad.toFloat())
        if (style.shadow) {
            val shadowPaint = TextPaint(paint).apply {
                color = Color.argb(166, 0, 0, 0)
                maskFilter = BlurMaskFilter(max(0.5f, 0.18f * fontSize), BlurMaskFilter.Blur.NORMAL)
            }
            c.save(); c.translate(0f, 0.06f * fontSize)
            layout(layout.text.toString(), shadowPaint, layout.width).draw(c)
            c.restore()
        }
        val outlineColor = style.outlineColor
        if (outlineColor != null && outline > 0) {
            val strokePaint = TextPaint(paint).apply {
                this.style = Paint.Style.STROKE
                strokeWidth = outline
                strokeJoin = Paint.Join.ROUND
                color = outlineColor.argb()
            }
            layout(layout.text.toString(), strokePaint, layout.width).draw(c)
        }
        layout.draw(c)
        c.restore()
        return bmp
    }

    fun layout(text: String, paint: TextPaint, width: Int): StaticLayout =
        StaticLayout.Builder.obtain(text, 0, text.length, paint, width.coerceAtLeast(1))
            .setAlignment(Layout.Alignment.ALIGN_CENTER)
            .setIncludePad(false)
            .build().let { l ->
                // Shrink the layout width to the widest line so short text isn't padded to 0.9 W.
                val widest = (0 until l.lineCount).maxOf { ceil(l.getLineWidth(it).toDouble()).toInt() }.coerceAtLeast(1)
                if (widest >= width) l else StaticLayout.Builder.obtain(text, 0, text.length, paint, widest)
                    .setAlignment(Layout.Alignment.ALIGN_CENTER).setIncludePad(false).build()
            }
}

/** Opening / closing slide image, 2160 px square (IMPLEMENTATION §8.9). */
object TitleCardRenderer {
    const val SIDE = 2160

    fun render(card: TitleCard, side: Int = SIDE): Bitmap {
        val bmp = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val s = side.toFloat()
        c.drawColor(card.background.copy(a = 1.0).argb())
        if (card.gradient) {
            val accent = card.accent.argb()
            val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(0.5f * s, 0.55f * s, 0.55f * s,
                    intArrayOf(Color.argb(115, Color.red(accent), Color.green(accent), Color.blue(accent)), Color.argb(0, Color.red(accent), Color.green(accent), Color.blue(accent))),
                    null, Shader.TileMode.CLAMP)
            }
            c.drawRect(0f, 0f, s, s, glow)
            val vignette = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(0.5f * s, 0.5f * s, 0.75f * s, intArrayOf(Color.argb(0, 0, 0, 0), Color.argb(0, 0, 0, 0), Color.argb(89, 0, 0, 0)),
                    floatArrayOf(0f, 0.35f / 0.75f, 1f), Shader.TileMode.CLAMP)
            }
            c.drawRect(0f, 0f, s, s, vignette)
        }
        val maxW = (0.48f * s).toInt()
        val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Fonts.typeface("HelveticaNeue-Bold"); textSize = 0.075f * s; color = card.textColor.copy(a = 1.0).argb()
        }
        val subPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Fonts.typeface("HelveticaNeue-Medium"); textSize = 0.034f * s
            color = card.textColor.copy(a = 0.75).argb()
        }
        val title = TextRenderer.layout(card.title.ifBlank { " " }, titlePaint, maxW)
        val sub = if (card.subtitle.isNotBlank()) TextRenderer.layout(card.subtitle, subPaint, maxW) else null
        val gap = 0.03f * s
        val barW = 0.07f * s; val barH = 0.008f * s
        val total = title.height + gap + barH + (if (sub != null) gap + sub.height else 0f)
        var y = (s - total) / 2
        c.save(); c.translate((s - title.width) / 2, y); title.draw(c); c.restore()
        y += title.height + gap
        c.drawRoundRect(RectF((s - barW) / 2, y, (s + barW) / 2, y + barH), barH / 2, barH / 2,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = card.accent.copy(a = 1.0).argb() })
        y += barH + gap
        if (sub != null) { c.save(); c.translate((s - sub.width) / 2, y); sub.draw(c); c.restore() }
        return bmp
    }

    fun write(card: TitleCard, file: File) {
        file.parentFile?.mkdirs()
        FileOutputStream(file).use { render(card).compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
