package com.mujassir.cutline.core.render

import kotlin.math.max
import kotlin.math.min

/** A colour look (FLT, IMPLEMENTATION §8.4): a formula on RGB in 0…1. */
data class FilterLook(val id: String, val name: String, val apply: (Rgb) -> Rgb)

data class Rgb(val r: Double, val g: Double, val b: Double) {
    operator fun times(k: Double) = Rgb(r * k, g * k, b * k)
    operator fun times(k: Rgb) = Rgb(r * k.r, g * k.g, b * k.b)
    operator fun plus(o: Rgb) = Rgb(r + o.r, g + o.g, b + o.b)
    fun clamped() = Rgb(r.coerceIn(0.0, 1.0), g.coerceIn(0.0, 1.0), b.coerceIn(0.0, 1.0))
}

object FilterLooks {
    fun luma(c: Rgb) = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
    fun saturate(c: Rgb, a: Double): Rgb { val l = luma(c); return Rgb(l + (c.r - l) * a, l + (c.g - l) * a, l + (c.b - l) * a) }
    fun contrast(c: Rgb, a: Double) = Rgb((c.r - 0.5) * a + 0.5, (c.g - 0.5) * a + 0.5, (c.b - 0.5) * a + 0.5)
    fun smooth(x: Double): Double { val t = x.coerceIn(0.0, 1.0); return t * t * (3 - 2 * t) }
    fun sCurve(x: Double, k: Double): Double { val t = x.coerceIn(0.0, 1.0); return t + (smooth(t) - t) * k }
    fun curve(c: Rgb, k: Double) = Rgb(sCurve(c.r, k), sCurve(c.g, k), sCurve(c.b, k))
    fun lift(c: Rgb, b: Double) = Rgb(c.r * (1 - b) + b, c.g * (1 - b) + b, c.b * (1 - b) + b)
    fun splitTone(c: Rgb, sh: Rgb, hi: Rgb, a: Double): Rgb {
        val l = luma(c)
        fun ch(cv: Double, s: Double, h: Double) = cv + ((s * (1 - l) + h * l) - 0.5) * a
        return Rgb(ch(c.r, sh.r, hi.r), ch(c.g, sh.g, hi.g), ch(c.b, sh.b, hi.b))
    }

    /** "None" plus 20 looks, in panel order (FLT-1). */
    val ALL: List<FilterLook> = listOf(
        FilterLook("vivid", "Vivid") { curve(saturate(it, 1.35), 0.35) },
        FilterLook("warm", "Warm") { curve(Rgb(it.r * 1.08 + 0.02, it.g * 1.02, it.b * 0.88), 0.15) },
        FilterLook("cool", "Cool") { Rgb(it.r * 0.9, it.g, it.b * 1.1 + 0.03) },
        FilterLook("teal_orange", "Cinema") { curve(splitTone(saturate(it, 1.1), Rgb(0.35, 0.55, 0.62), Rgb(0.68, 0.52, 0.38), 0.35), 0.3) },
        FilterLook("film", "Film") { lift(curve(saturate(it, 0.85), 0.25), 0.06) * Rgb(1.02, 1.0, 0.95) },
        FilterLook("fade", "Fade") { lift(saturate(it, 0.8), 0.12) },
        FilterLook("vintage", "Vintage") { val s = saturate(it, 0.7); lift(Rgb(s.r * 1.07, s.g * 0.98, s.b * 0.82), 0.08) },
        FilterLook("mono", "Mono") { val l = luma(it); Rgb(l, l, l) },
        FilterLook("noir", "Noir") { val l = sCurve(luma(it), 0.9); val v = l * l * 1.05; Rgb(v, v, v) },
        FilterLook("sepia", "Sepia") { val l = luma(it); Rgb(l * 1.07 + 0.05, l * 0.9 + 0.03, l * 0.7) },
        FilterLook("pastel", "Pastel") { lift(saturate(it, 0.75), 0.1) * Rgb(1.0, 0.98, 1.02) },
        FilterLook("punch", "Punch") { contrast(saturate(it, 1.25), 1.2) },
        FilterLook("golden", "Golden Hour") { curve(splitTone(it, Rgb(0.45, 0.4, 0.5), Rgb(0.75, 0.55, 0.3), 0.4), 0.2) },
        FilterLook("moody", "Moody") { val s = saturate(it, 0.75); curve(splitTone(s, Rgb(0.4, 0.5, 0.55), Rgb(0.55, 0.5, 0.45), 0.3), 0.4) * 0.95 },
        FilterLook("lush", "Lush") { val s = saturate(it, 1.2); Rgb(s.r * 0.97, s.g * 1.06, s.b * 0.98) },
        FilterLook("bleach", "Bleach") { val l = luma(it); curve(it * 0.5 + Rgb(l, l, l) * 0.5, 0.6) },
        FilterLook("night", "Night") { Rgb(it.r * 0.75, it.g * 0.9, it.b * 1.15 + 0.02) * 0.9 },
        FilterLook("rose", "Rose") { Rgb(it.r * 1.06 + 0.02, it.g * 0.96, it.b + 0.02) },
        FilterLook("matte", "Matte") { lift(curve(it, 0.2), 0.09) * 0.96 },
        FilterLook("chrome", "Chrome") { curve(saturate(it, 1.15), 0.55) },
    )

    fun look(id: String): FilterLook? = ALL.firstOrNull { it.id == id }

    fun grade(id: String, c: Rgb): Rgb = (look(id)?.apply?.invoke(c) ?: c).clamped()

    const val LUT_SIZE = 33

    /**
     * 33³ lookup table as an RGBA8 2D strip (width 33×33, height 33): texel (r + b×33, g) holds the
     * graded colour of (r, g, b) / 32. The shader samples it with manual trilinear filtering.
     */
    fun lutStrip(id: String): ByteArray {
        val n = LUT_SIZE
        val out = ByteArray(n * n * n * 4)
        for (b in 0 until n) for (g in 0 until n) for (r in 0 until n) {
            val c = grade(id, Rgb(r / (n - 1.0), g / (n - 1.0), b / (n - 1.0)))
            val i = ((g * n * n) + (b * n) + r) * 4
            out[i] = (c.r * 255 + 0.5).toInt().coerceIn(0, 255).toByte()
            out[i + 1] = (c.g * 255 + 0.5).toInt().coerceIn(0, 255).toByte()
            out[i + 2] = (c.b * 255 + 0.5).toInt().coerceIn(0, 255).toByte()
            out[i + 3] = 255.toByte()
        }
        return out
    }

    /** CPU version of the shader's adjust step (§8.3 step 5), used for thumbnails and Enhance. */
    fun adjust(c0: Rgb, exposure: Double, contrast: Double, saturation: Double, warmth: Double, highlights: Double, shadows: Double): Rgb {
        var c = c0 * Math.pow(2.0, exposure * 1.5)
        val l = luma(c)
        val hw = smoothstepRange(0.45, 1.0, l)
        val sw = 1 - smoothstepRange(0.0, 0.55, l)
        c = c + c * (highlights * 0.45 * hw)
        c = c + Rgb(1.0, 1.0, 1.0) * (shadows * 0.35 * sw)
        c = Rgb((c.r - 0.5) * (1 + contrast * 0.8) + 0.5, (c.g - 0.5) * (1 + contrast * 0.8) + 0.5, (c.b - 0.5) * (1 + contrast * 0.8) + 0.5)
        val l2 = luma(c)
        c = Rgb(l2 + (c.r - l2) * (1 + saturation), l2 + (c.g - l2) * (1 + saturation), l2 + (c.b - l2) * (1 + saturation))
        c = Rgb(c.r + warmth * 0.08, c.g, c.b - warmth * 0.08)
        return c.clamped()
    }

    fun smoothstepRange(e0: Double, e1: Double, x: Double): Double {
        val t = ((x - e0) / (e1 - e0)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

}
