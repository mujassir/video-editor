package com.mujassir.cutline.core.render

import com.mujassir.cutline.core.ClipAnimation
import com.mujassir.cutline.core.ClipCombo
import com.mujassir.cutline.core.ClipEntrance
import com.mujassir.cutline.core.ClipTransform
import com.mujassir.cutline.core.ContentAnchor
import com.mujassir.cutline.core.ContentFit
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.PhotoMotion
import com.mujassir.cutline.core.ReframeKeyframe
import com.mujassir.cutline.core.Size
import com.mujassir.cutline.core.TransitionKind
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

data class Vec2(val x: Double, val y: Double) {
    operator fun plus(o: Vec2) = Vec2(x + o.x, y + o.y)
    operator fun times(k: Double) = Vec2(x * k, y * k)
    companion object { val ZERO = Vec2(0.0, 0.0) }
}

/** One quad corner: NDC position, raw-frame UV, and output-local coordinate (0…1). */
data class QuadVertex(val px: Float, val py: Float, val u: Float, val v: Float, val lx: Float, val ly: Float)

/** Per-frame visual parameters (IMPLEMENTATION §8.5). */
data class LayerAnimation(
    val opacity: Double = 1.0,
    val brightness: Double = 1.0,
    /** Canvas-normalized (1 = full canvas width / height). */
    val offset: Vec2 = Vec2.ZERO,
    val scale: Double = 1.0,
    val blurRadius: Double = 0.0,
    val wipeProgress: Double = -1.0,
    val glitch: Double = 0.0,
    /** Radians, clockwise on screen. */
    val rotation: Double = 0.0,
)

/** Port of iOS LayerGeometry (IMPLEMENTATION §8.2 and §8.5), line for line. */
object LayerGeometry {
    /** Maps an upright point back to raw-frame UV for clockwise source quarter turns. */
    fun unrotate(p: Vec2, turns: Int): Vec2 {
        var q = p
        repeat(((turns % 4) + 4) % 4) { q = Vec2(q.y, 1 - q.x) }
        return q
    }

    fun displaySize(media: MediaItem, transform: ClipTransform): Size {
        val w = media.naturalSize.width * transform.crop.width
        val h = media.naturalSize.height * transform.crop.height
        return if (transform.quarterTurns % 2 == 1) Size(h, w) else Size(w, h)
    }

    fun reframeOffset(center: Vec2, contentSize: Size, canvas: Size): Vec2 {
        val ox = max(0.0, contentSize.width - canvas.width) / canvas.width
        val oy = max(0.0, contentSize.height - canvas.height) / canvas.height
        val dx = (0.5 - center.x) * contentSize.width / canvas.width
        val dy = (0.5 - center.y) * contentSize.height / canvas.height
        return Vec2(dx.coerceIn(-ox / 2, ox / 2), dy.coerceIn(-oy / 2, oy / 2))
    }

    fun reframeCenter(keys: List<ReframeKeyframe>, time: MediaTime): Vec2? {
        val first = keys.firstOrNull() ?: return null
        if (time <= first.time) return Vec2(first.centerX, first.centerY)
        for ((a, b) in keys.zipWithNext()) {
            if (time >= a.time && time <= b.time) {
                val span = (b.time - a.time).ticks.toDouble()
                val t = if (span > 0) (time - a.time).ticks / span else 0.0
                val s = t * t * (3 - 2 * t)
                return Vec2(a.centerX + (b.centerX - a.centerX) * s, a.centerY + (b.centerY - a.centerY) * s)
            }
        }
        val last = keys.last()
        return Vec2(last.centerX, last.centerY)
    }

    /** Triangle-strip quad (TL, TR, BL, BR) for a clip layer. */
    fun quad(
        media: MediaItem, transform: ClipTransform, sourceTurns: Int, canvas: Size,
        animation: LayerAnimation = LayerAnimation(), reframe: Vec2? = null, forceFill: Boolean = false,
    ): List<QuadVertex> {
        val content = displaySize(media, transform)
        if (content.width <= 0 || content.height <= 0 || canvas.width <= 0 || canvas.height <= 0) return emptyList()
        val fill = forceFill || transform.fit == ContentFit.FILL || reframe != null
        val stretch = transform.fit == ContentFit.STRETCH && !forceFill && reframe == null
        val sx = canvas.width / content.width
        val sy = canvas.height / content.height
        val base = if (fill) max(sx, sy) else min(sx, sy)
        val zoom = transform.scale * animation.scale
        val size = if (stretch) Size(canvas.width * zoom, canvas.height * zoom)
        else Size(content.width * base * zoom, content.height * base * zoom)

        var cx = 0.5
        var cy = 0.5
        val anchor = transform.anchor
        if (!stretch && reframe == null && anchor != null && anchor != ContentAnchor.CENTER) {
            val dx = (size.width - canvas.width) / canvas.width / 2
            val dy = (size.height - canvas.height) / canvas.height / 2
            when (anchor) {
                ContentAnchor.LEFT -> cx += dx
                ContentAnchor.RIGHT -> cx -= dx
                ContentAnchor.TOP -> cy += dy
                ContentAnchor.BOTTOM -> cy -= dy
                ContentAnchor.CENTER -> {}
            }
        }
        cx += transform.offsetX * 0.5 + animation.offset.x
        cy += transform.offsetY * 0.5 + animation.offset.y
        if (reframe != null) {
            val d = reframeOffset(reframe, size, canvas)
            cx += d.x; cy += d.y
        }
        val hw = size.width / canvas.width / 2
        val hh = size.height / canvas.height / 2
        var corners = listOf(Vec2(cx - hw, cy - hh), Vec2(cx + hw, cy - hh), Vec2(cx - hw, cy + hh), Vec2(cx + hw, cy + hh))
        if (animation.rotation != 0.0) {
            val c = cos(animation.rotation); val s = sin(animation.rotation)
            corners = corners.map { p ->
                val dx = (p.x - cx) * canvas.width; val dy = (p.y - cy) * canvas.height
                Vec2(cx + (dx * c - dy * s) / canvas.width, cy + (dx * s + dy * c) / canvas.height)
            }
        }
        val locals = listOf(Vec2(0.0, 0.0), Vec2(1.0, 0.0), Vec2(0.0, 1.0), Vec2(1.0, 1.0))
        val crop = transform.crop
        return corners.zip(locals).map { (corner, local) ->
            var p = local
            if (transform.flipHorizontal) p = Vec2(1 - p.x, p.y)
            if (transform.flipVertical) p = Vec2(p.x, 1 - p.y)
            p = unrotate(p, transform.quarterTurns)
            val display = Vec2(crop.x + p.x * crop.width, crop.y + p.y * crop.height)
            val raw = unrotate(display, sourceTurns)
            QuadVertex((corner.x * 2 - 1).toFloat(), (1 - corner.y * 2).toFloat(), raw.x.toFloat(), raw.y.toFloat(), local.x.toFloat(), local.y.toFloat())
        }
    }

    fun photoMotion(motion: PhotoMotion, progress: Double): LayerAnimation {
        val t = progress.coerceIn(0.0, 1.0)
        val e = t * t * (3 - 2 * t)
        val pan = 0.06
        return when (motion) {
            PhotoMotion.NONE -> LayerAnimation()
            PhotoMotion.ZOOM_IN -> LayerAnimation(scale = 1.0 + 0.25 * e)
            PhotoMotion.ZOOM_OUT -> LayerAnimation(scale = 1.25 - 0.25 * e)
            PhotoMotion.PAN_LEFT -> LayerAnimation(scale = 1.18, offset = Vec2(pan - 2 * pan * e, 0.0))
            PhotoMotion.PAN_RIGHT -> LayerAnimation(scale = 1.18, offset = Vec2(-pan + 2 * pan * e, 0.0))
            PhotoMotion.PAN_UP -> LayerAnimation(scale = 1.18, offset = Vec2(0.0, pan - 2 * pan * e))
            PhotoMotion.PAN_DOWN -> LayerAnimation(scale = 1.18, offset = Vec2(0.0, -pan + 2 * pan * e))
            PhotoMotion.KEN_BURNS -> LayerAnimation(scale = 1.08 + 0.2 * e, offset = Vec2(-0.035 + 0.07 * e, 0.025 - 0.05 * e))
        }
    }

    fun combine(a: LayerAnimation, b: LayerAnimation) = a.copy(
        scale = a.scale * b.scale,
        offset = a.offset + b.offset,
        opacity = a.opacity * b.opacity,
        brightness = a.brightness * b.brightness,
        blurRadius = max(a.blurRadius, b.blurRadius),
        glitch = max(a.glitch, b.glitch),
        rotation = a.rotation + b.rotation,
        wipeProgress = if (b.wipeProgress >= 0) b.wipeProgress else a.wipeProgress,
    )

    fun entrance(kind: ClipEntrance, progress: Double): LayerAnimation {
        val t = progress.coerceIn(0.0, 1.0)
        val e = 1 - (1 - t).pow(3)
        val inv = 1 - e
        return when (kind) {
            ClipEntrance.FADE -> LayerAnimation(opacity = t)
            ClipEntrance.ZOOM_IN -> LayerAnimation(scale = 0.3 + 0.7 * e, opacity = min(1.0, t * 2))
            ClipEntrance.ZOOM_OUT -> LayerAnimation(scale = 1.6 - 0.6 * e, opacity = min(1.0, t * 2))
            ClipEntrance.SLIDE_LEFT -> LayerAnimation(offset = Vec2(inv, 0.0))
            ClipEntrance.SLIDE_RIGHT -> LayerAnimation(offset = Vec2(-inv, 0.0))
            ClipEntrance.SLIDE_UP -> LayerAnimation(offset = Vec2(0.0, inv))
            ClipEntrance.SLIDE_DOWN -> LayerAnimation(offset = Vec2(0.0, -inv))
            ClipEntrance.ROTATE -> LayerAnimation(rotation = -PI / 2 * inv, scale = 0.6 + 0.4 * e, opacity = min(1.0, t * 2))
            ClipEntrance.SPIN -> LayerAnimation(rotation = -2 * PI * inv, scale = 0.2 + 0.8 * e, opacity = min(1.0, t * 1.5))
            ClipEntrance.POP -> {
                val back = 1.9; val u = t - 1
                LayerAnimation(scale = max(0.01, 1 + (back + 1) * u * u * u + back * u * u), opacity = min(1.0, t * 3))
            }
            ClipEntrance.BOUNCE -> LayerAnimation(scale = max(0.01, bounceOut(t)))
            ClipEntrance.DROP -> LayerAnimation(offset = Vec2(0.0, -(1 - bounceOut(t))))
            ClipEntrance.BLUR -> LayerAnimation(blurRadius = inv * 28, opacity = min(1.0, t * 1.5))
            ClipEntrance.SWING -> LayerAnimation(rotation = 0.5 * inv * cos(t * PI * 3), opacity = min(1.0, t * 2))
        }
    }

    fun bounceOut(t: Double): Double {
        val n = 7.5625; val d = 2.75
        if (t < 1 / d) return n * t * t
        if (t < 2 / d) { val u = t - 1.5 / d; return n * u * u + 0.75 }
        if (t < 2.5 / d) { val u = t - 2.25 / d; return n * u * u + 0.9375 }
        val u = t - 2.625 / d
        return n * u * u + 0.984375
    }

    fun combo(kind: ClipCombo, seconds: Double): LayerAnimation {
        val w = 2 * PI
        val s = seconds
        return when (kind) {
            ClipCombo.PULSE -> LayerAnimation(scale = 1 + 0.05 * (0.5 - 0.5 * cos(w * s)))
            ClipCombo.HEARTBEAT -> {
                val ph = s % 1.0
                val beat = exp(-((ph - 0.1) / 0.05).pow(2)) + 0.7 * exp(-((ph - 0.3) / 0.05).pow(2))
                LayerAnimation(scale = 1 + 0.07 * beat)
            }
            ClipCombo.SHAKE -> LayerAnimation(offset = Vec2(0.012 * sin(w * s * 7) * (0.6 + 0.4 * sin(w * s * 1.3)), 0.006 * sin(w * s * 11)))
            ClipCombo.WOBBLE -> LayerAnimation(rotation = 0.06 * sin(w * s * 2))
            ClipCombo.SWING -> LayerAnimation(rotation = 0.1 * sin(w * s / 1.6))
            ClipCombo.FLOAT -> LayerAnimation(offset = Vec2(0.0, 0.02 * sin(w * s / 2.4)))
            ClipCombo.ROCK -> LayerAnimation(rotation = 0.05 * sin(w * s / 1.2), scale = 1.04)
            ClipCombo.SPIN -> LayerAnimation(rotation = w * s / 6)
        }
    }

    /** Entrance, exit and combo at clip-local time (seconds). */
    fun clipAnimation(anim: ClipAnimation, local: Double, duration: Double): LayerAnimation {
        var r = LayerAnimation()
        anim.combo?.let { r = combine(r, combo(it, local)) }
        val inLen = min(anim.inDuration, duration / 2)
        val outLen = min(anim.outDuration, duration / 2)
        val e = anim.entrance
        if (e != null && inLen > 0 && local < inLen) r = combine(r, entrance(e, local / inLen))
        val x = anim.exit
        if (x != null && outLen > 0 && local > duration - outLen) r = combine(r, entrance(x, (duration - local) / outLen))
        return r
    }

    fun transitionAnimation(kind: TransitionKind, progress: Double, incoming: Boolean): LayerAnimation {
        val p = progress.coerceIn(0.0, 1.0)
        val e = p * p * (3 - 2 * p)
        return when (kind) {
            TransitionKind.FADE -> if (incoming) LayerAnimation(opacity = if (p < 0.5) 0.0 else 1.0, brightness = max(0.0, p * 2 - 1))
            else LayerAnimation(brightness = max(0.0, 1 - p * 2))
            TransitionKind.DISSOLVE -> if (incoming) LayerAnimation(opacity = e) else LayerAnimation()
            TransitionKind.SLIDE_LEFT -> LayerAnimation(offset = Vec2(if (incoming) 1 - e else -e, 0.0))
            TransitionKind.SLIDE_UP -> LayerAnimation(offset = Vec2(0.0, if (incoming) 1 - e else -e))
            TransitionKind.ZOOM -> if (incoming) LayerAnimation(scale = 1.4 - 0.4 * e, opacity = e) else LayerAnimation(scale = 1 + 0.4 * e)
            TransitionKind.WIPE -> if (incoming) LayerAnimation(wipeProgress = e) else LayerAnimation()
            TransitionKind.BLUR -> {
                val radius = sin(p * PI) * 24
                if (incoming) LayerAnimation(blurRadius = radius, opacity = e) else LayerAnimation(blurRadius = radius)
            }
            TransitionKind.GLITCH -> {
                val g = sin(p * PI)
                if (incoming) LayerAnimation(glitch = g, opacity = if (p < 0.5) 0.0 else 1.0) else LayerAnimation(glitch = g)
            }
        }
    }

    /** Older text animation (§8.6.1) helper: smoothstep. */
    fun smoothstep(x: Double): Double { val t = x.coerceIn(0.0, 1.0); return t * t * (3 - 2 * t) }

    fun fract(x: Double) = x - floor(x)
}
