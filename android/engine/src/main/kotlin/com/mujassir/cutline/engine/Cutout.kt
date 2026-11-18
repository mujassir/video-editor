package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Color
import com.mujassir.cutline.core.BackgroundReplacement
import com.mujassir.cutline.core.RGBAColor
import kotlin.math.max
import kotlin.math.min

/**
 * Cutout (CUT) compositor maths — IMPLEMENTATION §10.4 / §8.3 step 9.
 *
 * Softens a person mask with `smoothstep(0.15, 0.85)`, then applies Transparent / Blur / Colour.
 * Person-segmentation (ML Kit / MediaPipe) feeds [mask]; until that lands, callers can pass a
 * synthetic mask for tests and keep the panel wired.
 */
object Cutout {
    /** Soft edge on a 0…1 mask value (person = 1). */
    fun softEdge(mask: Float): Float = smoothstep(0.15f, 0.85f, mask)

    fun smoothstep(edge0: Float, edge1: Float, x: Float): Float {
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
        return t * t * (3f - 2f * t)
    }

    /**
     * Applies cutout to one pixel. [fg] is the processed clip RGB, [bg] the replacement
     * (blurred frame or solid colour; ignored for Transparent), [mask] is soft-edged 0…1.
     */
    fun mix(fg: FloatArray, bg: FloatArray, alpha: Float, mask: Float, mode: BackgroundReplacement): FloatArray {
        val m = softEdge(mask)
        return when (mode) {
            BackgroundReplacement.Transparent -> floatArrayOf(fg[0] * m, fg[1] * m, fg[2] * m, alpha * m)
            BackgroundReplacement.Blur,
            is BackgroundReplacement.Color -> floatArrayOf(
                fg[0] * m + bg[0] * (1 - m),
                fg[1] * m + bg[1] * (1 - m),
                fg[2] * m + bg[2] * (1 - m),
                alpha,
            )
        }
    }

    /** CPU apply for unit tests / still export paths. [mask] is grayscale 0…255, person bright. */
    fun applyMask(
        source: Bitmap,
        mask: Bitmap,
        replacement: BackgroundReplacement,
        blurredBackground: Bitmap? = null,
    ): Bitmap {
        val w = source.width
        val h = source.height
        require(mask.width == w && mask.height == h)
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val solid = (replacement as? BackgroundReplacement.Color)?.color
        val sigma = w / 60f
        val blurBg = blurredBackground ?: if (replacement == BackgroundReplacement.Blur) {
            boxBlur(source, max(1, (sigma / 2f).toInt()))
        } else null
        val sp = IntArray(w * h)
        val mp = IntArray(w * h)
        val bp = if (blurBg != null) IntArray(w * h) else null
        source.getPixels(sp, 0, w, 0, 0, w, h)
        mask.getPixels(mp, 0, w, 0, 0, w, h)
        blurBg?.getPixels(bp!!, 0, w, 0, 0, w, h)
        val outPx = IntArray(w * h)
        for (i in sp.indices) {
            val s = sp[i]
            val fg = floatArrayOf(
                ((s shr 16) and 0xFF) / 255f,
                ((s shr 8) and 0xFF) / 255f,
                (s and 0xFF) / 255f,
            )
            val a = ((s ushr 24) and 0xFF) / 255f
            val maskV = ((mp[i] shr 16) and 0xFF) / 255f // use R of grayscale
            val bg = when {
                solid != null -> floatArrayOf(solid.r.toFloat(), solid.g.toFloat(), solid.b.toFloat())
                bp != null -> floatArrayOf(
                    ((bp[i] shr 16) and 0xFF) / 255f,
                    ((bp[i] shr 8) and 0xFF) / 255f,
                    (bp[i] and 0xFF) / 255f,
                )
                else -> floatArrayOf(0f, 0f, 0f)
            }
            val mixed = mix(fg, bg, a, maskV, replacement)
            val r = (mixed[0].coerceIn(0f, 1f) * 255).toInt()
            val g = (mixed[1].coerceIn(0f, 1f) * 255).toInt()
            val b = (mixed[2].coerceIn(0f, 1f) * 255).toInt()
            val alpha = (mixed[3].coerceIn(0f, 1f) * 255).toInt()
            outPx[i] = (alpha shl 24) or (r shl 16) or (g shl 8) or b
        }
        out.setPixels(outPx, 0, w, 0, 0, w, h)
        return out
    }

    /** Tiny box blur for Blur-mode tests (σ ≈ width/60 in the shader path). */
    fun boxBlur(src: Bitmap, radius: Int): Bitmap {
        val w = src.width
        val h = src.height
        val inPx = IntArray(w * h)
        src.getPixels(inPx, 0, w, 0, 0, w, h)
        val tmp = IntArray(w * h)
        val out = IntArray(w * h)
        val r = max(1, radius)
        // Horizontal.
        for (y in 0 until h) {
            for (x in 0 until w) {
                var rs = 0; var gs = 0; var bs = 0; var n = 0
                for (dx in -r..r) {
                    val xx = min(w - 1, max(0, x + dx))
                    val p = inPx[y * w + xx]
                    rs += (p shr 16) and 0xFF; gs += (p shr 8) and 0xFF; bs += p and 0xFF; n++
                }
                tmp[y * w + x] = Color.rgb(rs / n, gs / n, bs / n)
            }
        }
        // Vertical.
        for (y in 0 until h) {
            for (x in 0 until w) {
                var rs = 0; var gs = 0; var bs = 0; var n = 0
                for (dy in -r..r) {
                    val yy = min(h - 1, max(0, y + dy))
                    val p = tmp[yy * w + x]
                    rs += (p shr 16) and 0xFF; gs += (p shr 8) and 0xFF; bs += p and 0xFF; n++
                }
                out[y * w + x] = Color.rgb(rs / n, gs / n, bs / n)
            }
        }
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also {
            it.setPixels(out, 0, w, 0, 0, w, h)
        }
    }

    fun rgba(c: RGBAColor) = floatArrayOf(c.r.toFloat(), c.g.toFloat(), c.b.toFloat())
}
